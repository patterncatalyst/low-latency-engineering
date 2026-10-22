package io.patterncatalyst.lowlat.jvmcosts;

import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.LineReceiver;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutionException;

/**
 * Ch5 line consumer: the common receive path with the tracker as the handler. What differs between the
 * three variants is the JVM, not this code:
 *
 * <ul>
 *   <li>{@code unwarmed}: bind and receive straight away (the r01 behaviour).
 *   <li>{@code warmed}: {@code --warm-up N} replays N synthetic parcels in this JVM before it binds.
 *   <li>{@code aot-cache}: the same as {@code unwarmed}, launched with {@code -XX:AOTCache=...
 *       -XX:AOTMode=on}. A cache the JVM cannot use is then a startup failure, not a silent fallback.
 * </ul>
 *
 * Prints {@code ready:} once the socket is bound, which is what the time-to-ready measurement waits for.
 * With {@code --window N} the first N parcels get their own report (see {@code WindowedRecorders}).
 */
public final class Costs {

    static final String EXAMPLE = "05-jvm-costs";
    private static final String USAGE = "usage: jvm-costs [--variant NAME] [--bind HOST:PORT] [--expect N]"
            + " [--idle-timeout-ms MS] [--rcvbuf BYTES] [--window N] [--warm-up N] [--report FILE]"
            + " [--example NAME]";

    private Costs() {
    }

    /** {@code --warm-up} is the one flag the common parser does not know: split it off. */
    record Args(long warmUp, List<String> rest) {
        static Args split(String[] args) {
            long warmUp = 0;
            List<String> rest = new ArrayList<>();
            for (int i = 0; i < args.length; i++) {
                if (args[i].equals("--warm-up") && i + 1 < args.length) {
                    warmUp = Long.parseLong(args[++i]);
                } else {
                    rest.add(args[i]);
                }
            }
            if (warmUp < 0) {
                throw new IllegalArgumentException("--warm-up must be >= 0");
            }
            return new Args(warmUp, List.copyOf(rest));
        }
    }

    public static void main(String[] args) throws IOException, InterruptedException, ExecutionException {
        Config config;
        Args split;
        try {
            split = Args.split(args);
            Config base = Config.parse(List.of("--bind", "127.0.0.1:47250", "--example", EXAMPLE,
                    "--variant", "unwarmed"));
            config = Config.parse(split.rest(), base);
        } catch (Config.HelpRequested e) {
            System.out.println(USAGE);
            return;
        } catch (IllegalArgumentException e) { // includes NumberFormatException
            System.err.println("jvm-costs: " + e.getMessage());
            System.err.println(USAGE);
            System.exit(2);
            return;
        }
        if (config.report() != null && !LatencyRecorder.profileConfigured()) {
            System.err.println("jvm-costs: --report needs " + LatencyRecorder.PROFILE_ENV);
            System.exit(2);
        }

        if (split.warmUp() > 0) {
            WarmUp.Result replay = WarmUp.replay(split.warmUp());
            long compileMs = WarmUp.awaitCompilerQuiet();
            System.out.printf("warm-up: replayed %d parcels, handled %d, dropped %d; JIT compile time %d ms%n",
                    replay.sent(), replay.handled(), replay.dropped(), compileMs);
        }

        TrackerHandler handler = new TrackerHandler(config.window());
        try (LineReceiver receiver = new LineReceiver(config)) {
            System.out.printf("ready: variant %s on %s:%d%n", config.variant(), config.bindHost(), config.bindPort());
            System.out.flush(); // bound: a script reading a redirected stdout waits on this line
            LineReceiver.StopReason reason = receiver.run(handler);
            Instant end = Instant.now();

            System.out.printf("received %d dropped %d reordered %d (stopped: %s) in flight %d lanes %s%n",
                    receiver.received(), receiver.dropped(), receiver.reordered(), reason,
                    handler.inFlightCount(), Arrays.toString(handler.laneCounts()));
            System.out.printf("window-times: first=%s boundary=%s end=%s%n", handler.firstParcel(),
                    handler.windowEnd(), end);
            receiver.recorder().printSummary();
            if (receiver.windows() != null) {
                receiver.windows().first().printSummary();
                receiver.windows().steady().printSummary();
            }
            if (config.report() != null) {
                writeReports(config, split, receiver);
            }
        }
    }

    private static void writeReports(Config config, Args split, LineReceiver receiver) {
        String notes = ("warm_up=%d; window=%d; reordered=%d; rcvbuf_granted=%d; the first window includes"
                + " JIT and class-loading cost unless warm_up > 0 or an AOT cache is set")
                .formatted(split.warmUp(), config.window(), receiver.reordered(), receiver.grantedRcvbuf());
        Map<String, Object> runtime = receiver.runtime();
        Map<String, Object> windowRuntime = receiver.windowRuntime();
        Map<String, Object> aot = aotFromFlags();
        if (aot != null) {
            runtime.put("aot", aot);
            windowRuntime.put("aot", aot);
        }
        Path report = config.report();
        receiver.recorder().writeReport(report, notes, null, runtime);
        System.out.println("report: " + report);
        if (receiver.windows() != null) {
            for (Path window : receiver.windows().writeReports(report, notes, windowRuntime)) {
                System.out.println("report: " + window);
            }
        }
    }

    /**
     * The {@code runtime.aot} block from the JVM's own arguments: the cache file and the mode. Whether the
     * cache was used is not known here; with {@code -XX:AOTMode=on} an unusable cache stops the JVM at
     * startup, and the verify script checks the AOT log before it records {@code used}.
     */
    static Map<String, Object> aotFromFlags() {
        String cache = null;
        String mode = null;
        for (String argument : ManagementFactory.getRuntimeMXBean().getInputArguments()) {
            if (argument.startsWith("-XX:AOTCache=")) {
                cache = Path.of(argument.substring("-XX:AOTCache=".length())).getFileName().toString();
            } else if (argument.startsWith("-XX:AOTMode=")) {
                mode = argument.substring("-XX:AOTMode=".length());
            }
        }
        if (cache == null) {
            return null;
        }
        Map<String, Object> aot = new LinkedHashMap<>();
        aot.put("cache", cache);
        aot.put("mode", mode == null ? "auto" : mode);
        return aot;
    }
}
