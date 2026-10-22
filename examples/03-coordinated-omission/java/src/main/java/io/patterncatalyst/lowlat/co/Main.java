package io.patterncatalyst.lowlat.co;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.net.DatagramSocket;
import java.net.StandardSocketOptions;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/** {@code co-experiment-java run|probe}: Ch3 coordinated omission. See the example README. */
public final class Main {

    private static final String USAGE = """
            usage: co-experiment-java run   [--bind H:P] [--expect N] [--stall-ms MS] [--stall-seq N] [--suffix S] --out DIR
                   co-experiment-java probe [--out DIR]
            """;

    private Main() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.print(USAGE);
            System.exit(2);
        }
        Options o;
        try {
            o = Options.parse(List.of(args).subList(1, args.length));
        } catch (IllegalArgumentException e) {
            System.err.println("co-experiment-java: " + e.getMessage());
            System.err.print(USAGE);
            System.exit(2);
            return;
        }
        if (!LatencyRecorder.profileConfigured()) {
            System.err.println("co-experiment-java: " + LatencyRecorder.PROFILE_ENV
                    + " is not set (scripts/profile.sh --out FILE): a number without a profile is not publishable");
            System.exit(2);
        }
        Files.createDirectories(o.outDir());
        switch (args[0]) {
            case "run" -> run(o);
            case "probe" -> probe(o);
            default -> {
                System.err.print(USAGE);
                System.exit(2);
            }
        }
    }

    private static void run(Options o) throws IOException {
        Recorders rec = Recorders.create(o.suffix());
        try (DatagramSocket socket = new DatagramSocket(null)) {
            socket.setOption(StandardSocketOptions.SO_RCVBUF, o.rcvbuf());
            socket.bind(o.bindAddress());
            System.out.println("listening on " + o.bindHost() + ":" + o.bindPort());
            System.out.flush();
            long dropped = Experiment.receive(o, socket, rec);
            Experiment.closedLoop(o, o.expect(), rec);
            String notes = "stall_ms=%d stall_seq=%d dropped=%d; the stall is a blocking sleep; JIT not warmed"
                    .formatted(o.stallMs(), o.stallSeq(), dropped);
            emit(rec.receiptTime(), o.outDir(), notes);
            emit(rec.intendedTime(), o.outDir(), notes);
            emit(rec.closedLoopCorrected(), o.outDir(), notes + "; recordCorrected, expected interval 1 ms");
            emit(rec.closedLoopNaive(), o.outDir(), notes);
        }
    }

    private static void probe(Options o) {
        LatencyRecorder nano = LatencyRecorder.singleThreaded(Recorders.EXAMPLE, "clock-read");
        ClockProbe.run(1_000_000, nano);
        emit(nano, o.outDir(), "1e6 back-to-back pairs of System.nanoTime (CLOCK_MONOTONIC on Linux); value = second - first");
    }

    private static void emit(LatencyRecorder r, Path dir, String notes) {
        r.printSummary();
        r.writeReport(dir.resolve("java-" + r.report().variant() + ".json"), notes);
    }
}
