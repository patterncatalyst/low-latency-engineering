package io.patterncatalyst.lowlat.lockfree;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The read-side benchmark: one writer updates a parcel-state snapshot every microsecond (open loop: a
 * late update is not skipped) while three readers spin on it, on distinct pinned cores. The writer's
 * update time is the distribution; torn snapshots (a checksum that does not match) and the readers'
 * failed optimistic attempts are exact counts.
 */
final class SeqlockRun {

    private SeqlockRun() {
    }

    static SnapshotCell cellFor(String variant) {
        return switch (variant) {
            case "rw-lock" -> new SnapshotCell.ReadWrite();
            case "stamped-lock" -> new SnapshotCell.Stamped();
            default -> throw new IllegalArgumentException("--variant: rw-lock | stamped-lock");
        };
    }

    /** What a run measured, for the tests. */
    record Result(long updates, long reads, long torn, long retries) {
    }

    static void execute(String variant, Args args) throws Exception {
        Path report = args.report();
        if (report != null && !LatencyRecorder.profileConfigured()) {
            throw new IllegalStateException("--report needs " + LatencyRecorder.PROFILE_ENV);
        }
        int readers = (int) args.number("readers", 3);
        long durationMs = args.number("duration-ms", 2000);
        long periodNs = args.number("update-period-ns", 1000);
        List<Integer> cpus = args.cpus(readers + 1);
        Placement.Gate gate = new Placement.Gate(readers + 1, args.number("hold-ms", 0));
        LatencyRecorder updateNs = LatencyRecorder.singleThreaded(ClaimRun.EXAMPLE, variant);
        Result result = run(cellFor(variant), readers, durationMs, periodNs, cpus, gate, updateNs);

        Map<String, Object> runtime = RuntimeInfo.jvm();
        Map<String, Object> placement = Placement.placement(cpus);
        if (!placement.isEmpty()) {
            runtime.put("placement", placement);
        }
        runtime.put("counters", RuntimeInfo.counters(Map.of("updates", result.updates(), "reads", result.reads(),
                "torn_snapshots", result.torn(), "reader_retries", result.retries())));
        String notes = "seqlock; one writer at " + periodNs + " ns period (open loop), " + readers + " readers spinning, " + durationMs
                + " ms; a snapshot is " + SnapshotCell.WORDS + " words with a checksum; update time is System.nanoTime around write() only";
        updateNs.printSummary();
        if (report != null) {
            updateNs.writeReport(report, notes, null, runtime);
            System.out.println("report: " + report);
        }
    }

    static Result run(SnapshotCell cell, int readers, long durationMs, long periodNs, List<Integer> cpus, Placement.Gate gate,
            LatencyRecorder updateNs) throws Exception {
        AtomicBoolean stop = new AtomicBoolean();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        long[] updates = new long[1]; // the writer's, read after join
        long[][] totals = new long[readers][]; // {reads, torn, retries}: each reader stores its own once, read after join
        List<Thread> threads = new ArrayList<>();
        threads.add(Thread.ofPlatform().name("writer").uncaughtExceptionHandler(Placement.recordTo(failure)).unstarted(() -> {
            try (Placement.Pin _ = gate.workerReady(cpus.get(0), "writer")) {
                long[] snapshot = new long[SnapshotCell.WORDS];
                long due = System.nanoTime();
                for (long n = 1; !stop.get(); n++) {
                    due += periodNs;
                    while (System.nanoTime() < due) {
                        Thread.onSpinWait();
                    }
                    SnapshotCell.of(n, snapshot);
                    long t0 = System.nanoTime();
                    cell.write(snapshot);
                    updateNs.record(System.nanoTime() - t0);
                    updates[0]++;
                }
            }
        }));
        for (int r = 0; r < readers; r++) {
            int index = r;
            threads.add(Thread.ofPlatform().name("reader-" + r).uncaughtExceptionHandler(Placement.recordTo(failure))
                    .unstarted(() -> {
                        try (Placement.Pin _ = gate.workerReady(cpus.get(index + 1), "reader-" + index)) {
                            long[] snapshot = new long[SnapshotCell.WORDS];
                            long reads = 0;
                            long torn = 0;
                            long retries = 0;
                            while (!stop.get()) {
                                retries += cell.read(snapshot);
                                reads++;
                                if (!SnapshotCell.consistent(snapshot)) {
                                    torn++;
                                }
                            }
                            totals[index] = new long[] {reads, torn, retries};
                        }
                    }));
        }
        threads.forEach(Thread::start);
        gate.release();
        Thread.sleep(durationMs);
        stop.set(true);
        for (Thread thread : threads) {
            thread.join();
        }
        if (failure.get() != null) {
            throw new IllegalStateException("a thread failed", failure.get());
        }
        long reads = 0;
        long torn = 0;
        long retries = 0;
        for (long[] t : totals) {
            reads += t[0];
            torn += t[1];
            retries += t[2];
        }
        return new Result(updates[0], reads, torn, retries);
    }
}
