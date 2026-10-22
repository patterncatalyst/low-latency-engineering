package io.patterncatalyst.lowlat.flat;

import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.Decoder;
import io.patterncatalyst.lowlat.line.EventHandler;
import io.patterncatalyst.lowlat.line.EventReceiver;
import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

/**
 * The line consumer of Ch8: the common receive loop ({@link EventReceiver}) with the decoder as the
 * only difference between the two variants.
 *
 * <ul>
 *   <li>{@code protobuf-decode}: {@code Decoder.protobuf()}, a fresh {@code ParcelEvent} per datagram
 *       (feed it the simulator's default wire).
 *   <li>{@code flat-ffm}: {@link FlatDecoder}, a reused {@link FlatView} (feed it
 *       {@code line-simulator --wire flat}).
 * </ul>
 *
 * Both handlers do the r01 work (the sortation lane from the barcode) and complete the parcel at
 * once, so the latency is the same measurement as Ch0 to Ch3 and the difference between the two
 * reports is the decode. The report's {@code runtime.alloc_bytes_per_parcel} is what the receive
 * thread allocated per parcel, decode included.
 */
final class LineRun {

    static final String EXAMPLE = "08-zero-copy-flat";
    static final String PROTOBUF = "protobuf-decode";
    static final String FLAT = "flat-ffm";
    static final int DEFAULT_PORT = 47280;

    private static final String USAGE = """
            usage: Main consume --variant protobuf-decode|flat-ffm [--bind HOST:PORT] [--rcvbuf BYTES]
                                [--expect N] [--idle-timeout-ms MS] [--report FILE] [--window N]
              Options as line-consumer-java (consumers/README.md). Default bind 127.0.0.1:47280.
              flat-ffm reads the simulator's --wire flat; protobuf-decode its default wire.
            """;

    private LineRun() {
    }

    static int run(List<String> args) throws IOException {
        Config base = new Config("127.0.0.1", DEFAULT_PORT, 4 << 20, 0, 2000, null, EXAMPLE, PROTOBUF);
        Config config;
        try {
            config = Config.parse(args, base);
        } catch (Config.HelpRequested e) {
            System.out.print(USAGE);
            return 0;
        } catch (IllegalArgumentException e) {
            System.err.println("consume: " + e.getMessage());
            System.err.print(USAGE);
            return 2;
        }
        if (!config.variant().equals(PROTOBUF) && !config.variant().equals(FLAT)) {
            System.err.println("consume: --variant must be " + PROTOBUF + " or " + FLAT + ", got " + config.variant());
            return 2;
        }
        if (config.report() != null && !LatencyRecorder.profileConfigured()) {
            System.err.println("consume: --report needs " + LatencyRecorder.PROFILE_ENV
                    + " (run scripts/profile.sh --out FILE): a number without a profile is not publishable");
            return 2;
        }
        long[] laneCounts = new long[Lanes.LANES];
        if (config.variant().equals(FLAT)) {
            EventHandler<FlatView> handler = (view, done) -> {
                laneCounts[view.lane()]++;
                done.complete(view.seq(), view.intendedEmitNs(), System.nanoTime());
            };
            return receive(config, new EventReceiver<>(config, new FlatDecoder()), handler, laneCounts);
        }
        EventHandler<ParcelEvent> handler = (event, done) -> {
            laneCounts[Lanes.laneOf(event.getBarcode())]++;
            done.complete(event);
        };
        return receive(config, new EventReceiver<>(config, Decoder.protobuf()), handler, laneCounts);
    }

    private static <E> int receive(Config config, EventReceiver<E> receiver, EventHandler<E> handler, long[] laneCounts)
            throws IOException {
        try (receiver) {
            System.out.printf("listening on %s, SO_RCVBUF requested %d, granted %d%n",
                    receiver.localAddress(), config.rcvbuf(), receiver.grantedRcvbuf());
            System.out.flush(); // bound: a script reading a redirected stdout waits on this line
            EventReceiver.StopReason reason = receiver.run(handler);

            System.out.printf("stopped: %s; received %d, dropped %d, reordered %d, malformed %d%n", reason,
                    receiver.received(), receiver.dropped(), receiver.reordered(), receiver.malformed());
            System.out.println("lanes: " + Arrays.toString(laneCounts));
            LatencyRecorder recorder = receiver.recorder();
            recorder.printSummary();
            if (receiver.windows() != null) {
                receiver.windows().first().printSummary();
                receiver.windows().steady().printSummary();
            }
            Path report = config.report();
            if (report != null) {
                String notes = "reordered=%d; malformed=%d; rcvbuf_requested=%d; rcvbuf_granted=%d; wire=%s"
                        .formatted(receiver.reordered(), receiver.malformed(), config.rcvbuf(),
                                receiver.grantedRcvbuf(), config.variant().equals(FLAT) ? "flat" : "protobuf");
                Map<String, Object> runtime = receiver.runtime();
                recorder.writeReport(report, notes, null, runtime);
                System.out.println("report: " + report);
                if (receiver.windows() != null) {
                    for (Path window : receiver.windows().writeReports(report, notes, receiver.windowRuntime())) {
                        System.out.println("report: " + window);
                    }
                }
            }
            return reason == EventReceiver.StopReason.EXPECTED ? 0 : 1;
        } catch (EventReceiver.NegativeLatencyException e) {
            System.err.println("consume: aborting: " + e.getMessage());
            return 1;
        }
    }
}
