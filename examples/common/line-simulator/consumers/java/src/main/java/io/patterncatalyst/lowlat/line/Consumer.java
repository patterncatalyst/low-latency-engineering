package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/** Java line consumer: see {@code examples/common/line-simulator/consumers/README.md}. */
public final class Consumer {

    /** Upper bound on how long the shutdown hook waits for main to finish writing the report. */
    private static final long REPORT_WAIT_SECONDS = 60;

    private Consumer() {
    }

    public static void main(String[] args) throws Exception {
        Config config;
        try {
            config = Config.parse(List.of(args));
        } catch (Config.HelpRequested e) {
            System.out.print(Config.USAGE);
            return;
        } catch (IllegalArgumentException e) {
            System.err.println("line-consumer-java: " + e.getMessage());
            System.err.print(Config.USAGE);
            System.exit(2);
            return;
        }
        if (config.report() != null && !LatencyRecorder.profileConfigured()) {
            System.err.println("line-consumer-java: --report needs " + LatencyRecorder.PROFILE_ENV
                    + " (run scripts/profile.sh --out FILE): a number without a profile is not publishable");
            System.exit(2);
        }

        LineReceiver receiver;
        try {
            receiver = new LineReceiver(config);
        } catch (IOException e) {
            System.err.println("line-consumer-java: cannot bind " + config.bindHost() + ":"
                    + config.bindPort() + ": " + e.getMessage());
            System.exit(2);
            return;
        }
        System.out.printf("listening on %s, SO_RCVBUF requested %d, granted %d%n",
                receiver.localAddress(), config.rcvbuf(), receiver.grantedRcvbuf());
        System.out.flush(); // bound: a script reading a redirected stdout waits on this line

        // The task holds the stop reason or the failure; its state is reported and turned into an
        // exit status below.
        FutureTask<LineReceiver.StopReason> receive = new FutureTask<>(receiver::run);
        Thread loop = Thread.ofPlatform().name("line-consumer").unstarted(receive);
        // The report is written once, by whichever of main (the loop ended by itself) or the
        // shutdown hook (SIGINT/SIGTERM) gets here first.
        ReportGate reported = new ReportGate();
        // SIGINT/SIGTERM: stop the loop, wait for it (the join is also the happens-before edge to
        // the single-threaded recorder), then write the report. Nothing can set the exit status
        // from here, so a failed write halts the JVM with status 1.
        Runtime.getRuntime().addShutdownHook(Thread.ofPlatform().name("line-consumer-shutdown").unstarted(() -> {
            receiver.stop();
            try {
                loop.join();
                if (receive.state() == Future.State.FAILED) {
                    return;
                }
                if (reported.claim()) {
                    try {
                        finish(config, receiver, receive.state() == Future.State.SUCCESS ? receive.resultNow() : null);
                    } finally {
                        reported.done();
                    }
                } else if (!reported.awaitDone(REPORT_WAIT_SECONDS, TimeUnit.SECONDS)) {
                    // main is still writing: returning would let the JVM finish the shutdown mid-write
                    System.err.println("line-consumer-java: report write did not finish in "
                            + REPORT_WAIT_SECONDS + " s");
                    Runtime.getRuntime().halt(1);
                } else if (reported.hasFailed()) {
                    Runtime.getRuntime().halt(1); // main's write failed (already reported); keep status 1
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } catch (IOException | UncheckedIOException e) {
                System.err.println("line-consumer-java: cannot write report: " + e.getMessage());
                Runtime.getRuntime().halt(1);
            }
        }));

        loop.start();
        loop.join();
        if (receive.state() == Future.State.FAILED) {
            Throwable t = receive.exceptionNow();
            System.err.println("line-consumer-java: " + (t instanceof LineReceiver.NegativeLatencyException
                    ? "aborting: " + t.getMessage() : t));
            if (!(t instanceof LineReceiver.NegativeLatencyException)) {
                t.printStackTrace();
            }
            System.exit(1);
        }
        if (!reported.claim()) {
            return; // the shutdown hook is writing the report and ends the JVM
        }
        int status = 0;
        try {
            finish(config, receiver, receive.state() == Future.State.SUCCESS ? receive.resultNow() : null);
        } catch (IOException | UncheckedIOException e) {
            System.err.println("line-consumer-java: cannot write report: " + e.getMessage());
            status = 1;
            reported.failed();
        } finally {
            reported.done();
        }
        System.exit(status);
    }

    private static void finish(Config config, LineReceiver receiver, LineReceiver.StopReason reason)
            throws IOException {
        System.out.printf("stopped: %s%n", reason == null ? "REQUESTED" : reason);
        LatencyRecorder recorder = receiver.recorder();
        recorder.printSummary();
        System.out.println(receiver.notes());
        if (receiver.windows() != null) {
            receiver.windows().first().printSummary();
            receiver.windows().steady().printSummary();
        }
        Path report = config.report();
        if (report != null) {
            Map<String, Object> runtime = receiver.runtime();
            recorder.writeReport(report, receiver.reportNotes(), null, runtime);
            System.out.println("report: " + report);
            if (receiver.windows() != null) {
                for (Path window : receiver.windows().writeReports(report, receiver.reportNotes(), receiver.windowRuntime())) {
                    System.out.println("report: " + window);
                }
            }
        }
    }
}
