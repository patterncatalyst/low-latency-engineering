package io.patterncatalyst.lowlat.latdist;

import io.patterncatalyst.lowlat.line.Completion;
import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.LineReceiver;
import io.patterncatalyst.lowlat.line.ParcelHandler;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;

/**
 * Ch1 example: one receive path, three handling policies.
 *
 * <ul>
 *   <li>{@code per-parcel}: handle each parcel on arrival.
 *   <li>{@code batch-32}: hold 32 parcels, then handle them together; one done time per batch.
 *   <li>{@code bimodal-1pct}: per-parcel, but {@code seq % 100 == 0} runs a ~2 ms busy loop.
 * </ul>
 *
 * The common {@link LineReceiver} binds, parses, tracks gaps and records latency; this class
 * supplies only the {@link ParcelHandler}.
 */
public final class Latdist {

    private static final int BATCH = 32;
    private static final long SLOW_EVERY = 100;

    private Latdist() {
    }

    public static void main(String[] args) throws IOException {
        Config config;
        Policy policy;
        try {
            // --slow-us is the only flag the common parser does not know; the rest go to it, over
            // this example's defaults.
            long slowUs = 2000;
            List<String> rest = new ArrayList<>();
            for (int i = 0; i < args.length; i++) {
                if (args[i].equals("--slow-us") && i + 1 < args.length) {
                    slowUs = Long.parseLong(args[++i]);
                } else {
                    rest.add(args[i]);
                }
            }
            Config base = Config.parse(List.of("--bind", "127.0.0.1:47210", "--example", "01-latency-distribution",
                    "--variant", "per-parcel"));
            config = Config.parse(rest, base);
            policy = switch (config.variant()) {
                case "per-parcel" -> new PerParcel();
                case "batch-32" -> new Batch(BATCH);
                case "bimodal-1pct" -> new Bimodal(SLOW_EVERY, slowUs);
                default -> throw new IllegalArgumentException("--variant: per-parcel | batch-32 | bimodal-1pct");
            };
        } catch (Config.HelpRequested e) {
            System.out.println("usage: latdist-java [--variant per-parcel|batch-32|bimodal-1pct] [--bind HOST:PORT]"
                    + " [--expect N] [--idle-timeout-ms MS] [--slow-us US] [--rcvbuf BYTES] [--report FILE]"
                    + " [--example NAME]");
            return;
        } catch (IllegalArgumentException e) { // includes NumberFormatException
            System.err.println("latdist-java: " + e.getMessage());
            System.exit(2);
            return;
        }
        if (config.report() != null && !LatencyRecorder.profileConfigured()) {
            System.err.println("latdist-java: --report needs " + LatencyRecorder.PROFILE_ENV);
            System.exit(2);
        }

        try (LineReceiver receiver = new LineReceiver(config)) {
            System.out.println("latdist-java: variant " + config.variant() + " on " + config.bindHost() + ":"
                    + config.bindPort());
            System.out.flush(); // bound: a script reading a redirected stdout waits on this line
            LineReceiver.StopReason reason = receiver.run(policy);

            System.out.printf("received %d dropped %d reordered %d (stopped: %s) [%d]%n",
                    receiver.received(), receiver.dropped(), receiver.reordered(),
                    switch (reason) {
                        case EXPECTED -> "expect";
                        case IDLE -> "idle";
                        case REQUESTED -> "signal";
                    },
                    policy.laneSink & 1);
            Completion done = receiver.completion();
            long span = done.lastDoneNs() - done.firstDoneNs();
            // Completions per second x 1000, exact; one completion (or none) spans no time.
            String throughputMhz = span > 0
                    ? BigInteger.valueOf(done.count()).multiply(BigInteger.TEN.pow(12))
                            .divide(BigInteger.valueOf(span)).toString()
                    : "n/a";
            String notes = "throughput_mhz=%s; done_span_ns=%d; reordered=%d; JIT not warmed: first parcels included"
                    .formatted(throughputMhz, span, receiver.reordered())
                    + policy.notes();
            LatencyRecorder rec = receiver.recorder();
            rec.printSummary();
            if (config.report() != null) {
                rec.writeReport(config.report(), notes);
            }
        }
    }

    /** A handling policy: a {@link ParcelHandler} that also keeps the lane lookup observable. */
    private abstract static class Policy implements ParcelHandler {
        long laneSink;

        String notes() {
            return "";
        }
    }

    /** Handle the parcel on arrival. */
    private static final class PerParcel extends Policy {
        @Override
        public void onParcel(ParcelEvent event, Completion done) {
            laneSink += Lanes.laneOf(event.getBarcode());
            done.complete(event);
        }
    }

    /** Hold parcels until {@code size} have arrived, then complete them together. */
    private static final class Batch extends Policy {
        private record Pending(long intendedNs, String barcode) {
        }

        private final int size;
        private final List<Pending> pending;

        Batch(int size) {
            this.size = size;
            this.pending = new ArrayList<>(size);
        }

        @Override
        public void onParcel(ParcelEvent event, Completion done) {
            pending.add(new Pending(event.getIntendedEmitNs(), event.getBarcode()));
            if (pending.size() >= size) {
                flush(done);
            }
        }

        @Override
        public void drain(Completion done) { // a partial last batch still gets handled
            flush(done);
        }

        private void flush(Completion done) {
            for (Pending p : pending) {
                laneSink += Lanes.laneOf(p.barcode());
            }
            long doneNs = System.nanoTime(); // one completion time for the whole batch
            for (Pending p : pending) {
                done.complete(p.intendedNs(), doneNs);
            }
            pending.clear();
        }

        @Override
        String notes() {
            return "; batch=" + size;
        }
    }

    /** Per-parcel, but one in {@code every} takes the slow path: a busy loop, not a sleep. */
    private static final class Bimodal extends Policy {
        private final long every;
        private final long iterations;
        private final long measuredNs;
        private long slowCount;

        Bimodal(long every, long slowUs) {
            this.every = every;
            this.iterations = BusyWork.calibrate(slowUs);
            long t0 = System.nanoTime();
            BusyWork.spin(iterations);
            this.measuredNs = System.nanoTime() - t0;
            System.out.printf("calibrated slow path: %d iterations = %.1f us%n", iterations, measuredNs / 1e3);
        }

        @Override
        public void onParcel(ParcelEvent event, Completion done) {
            laneSink += Lanes.laneOf(event.getBarcode());
            if (event.getSeq() % every == 0) {
                laneSink += BusyWork.spin(iterations); // the re-lookup: real CPU work
                slowCount++;
            }
            done.complete(event);
        }

        @Override
        String notes() {
            return "; slow_every=%d; slow_parcels=%d; slow_path_us=%.1f; busy loop, not sleep"
                    .formatted(every, slowCount, measuredNs / 1e3);
        }
    }
}
