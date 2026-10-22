package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;

/** Java line consumer: see {@code examples/common/line-simulator/consumers/README.md}. */
public final class Consumer {

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
        // Runs on SIGINT/SIGTERM and on System.exit: stop the loop, wait for it (the join is also
        // the happens-before edge to the single-threaded recorder), then write the report.
        Runtime.getRuntime().addShutdownHook(Thread.ofPlatform().name("line-consumer-shutdown").unstarted(() -> {
            receiver.stop();
            try {
                loop.join();
                if (receive.state() != Future.State.FAILED) {
                    finish(config, receiver, receive.state() == Future.State.SUCCESS ? receive.resultNow() : null);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } catch (IOException e) {
                throw new UncheckedIOException(e);
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
        System.exit(0); // runs the shutdown hook, which writes the report
    }

    private static void finish(Config config, LineReceiver receiver, LineReceiver.StopReason reason)
            throws IOException {
        System.out.printf("stopped: %s%n", reason == null ? "REQUESTED" : reason);
        LatencyRecorder recorder = receiver.recorder();
        recorder.printSummary();
        System.out.println(receiver.notes());
        Path report = config.report();
        if (report != null) {
            recorder.writeReport(report, receiver.reportNotes());
            System.out.println("report: " + report);
        }
    }
}
