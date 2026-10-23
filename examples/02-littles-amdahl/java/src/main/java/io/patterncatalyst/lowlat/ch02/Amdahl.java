package io.patterncatalyst.lowlat.ch02;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.BrokenBarrierException;
import java.util.concurrent.CyclicBarrier;

/**
 * Amdahl's Law with a real serial section, Java edition: see {@code ../../README.md}.
 *
 * <p>A fixed batch of parcels is shared among N platform threads. Each parcel costs CPU work that
 * parallelises, then updates the shared sort-plan table inside one {@code synchronized} block: the
 * serial fraction. {@code synchronized} is the idiomatic critical section for a short, non-blocking
 * update with no need for tryLock, timeouts or conditions, and since JDK 24 (JEP 491) it no longer
 * pins virtual threads either; {@code ReentrantLock} would only add API surface here. The fraction
 * is measured: an instrumented one-worker run times every lock section.
 *
 * <p>Work is done in waves: a worker scans its K parcels, all workers meet at a {@link CyclicBarrier},
 * then every worker commits its K updates under the lock, and they meet again. The barriers make the
 * serial part strictly serial. Without them (--sync free) a lock section overlaps the other workers'
 * parallel work and the run beats the formula.
 */
public final class Amdahl {

    private static final int CELLS = 64;

    /** Worker counts of the speedup curve. */
    private static final int[] WORKERS = {1, 2, 4};

    private record Options(long batch, long roundParcels, boolean phased, long parallelIters, long lockIters,
                           int reps, int warmup, int calibrationRuns, Path reportDir, String example) {
        private static final Set<String> KEYS = Set.of("--batch", "--round-parcels", "--sync",
                "--parallel-iters", "--lock-iters", "--reps", "--warm-up", "--report-dir", "--example");

        static Options parse(String[] args) {
            Map<String, String> kv = Cli.pairs(args, KEYS);
            return new Options(
                    Long.parseLong(kv.getOrDefault("--batch", "3200")),
                    Long.parseLong(kv.getOrDefault("--round-parcels", "160")),
                    phased(kv.getOrDefault("--sync", "phased")),
                    Long.parseLong(kv.getOrDefault("--parallel-iters", "20000")),
                    Long.parseLong(kv.getOrDefault("--lock-iters", "2400")),
                    Integer.parseInt(kv.getOrDefault("--reps", "30")),
                    Integer.parseInt(kv.getOrDefault("--warm-up", "10")),
                    5,
                    Path.of(kv.getOrDefault("--report-dir", ".")),
                    kv.getOrDefault("--example", "02-littles-amdahl"));
        }

        private static boolean phased(String sync) {
            if (!sync.equals("phased") && !sync.equals("free")) {
                throw new IllegalArgumentException("--sync is 'phased' or 'free'");
            }
            return sync.equals("phased");
        }
    }

    /**
     * The sort-plan table. Updates are additions, so the final contents do not depend on which
     * worker got there first: every N must produce the same sum.
     */
    private static final class SortPlan {
        private final long[] cell = new long[CELLS];

        void reset() {
            Arrays.fill(cell, 0);
        }

        long checksum() {
            long sum = 0;
            for (long c : cell) {
                sum += c;
            }
            return sum;
        }

        /** Serial part; the caller holds this object's monitor. */
        void update(long weight, long iters) {
            long w = weight;
            for (long j = 0; j < iters; j++) {
                int at = (int) Long.remainderUnsigned(w >>> 7, CELLS);
                cell[at] += (w & 0xFFFF) + j;
                w = w * 6364136223846793005L + 1442695040888963407L;
            }
        }
    }

    /** Parallel part: a dependent integer mix keyed by the parcel number. */
    private static long scanWork(long parcel, long iters) {
        long x = parcel * 0x9E3779B97F4A7C15L + 1;
        for (long i = 0; i < iters; i++) {
            x ^= x >>> 29;
            x *= 0xBF58476D1CE4E5B9L;
        }
        return x;
    }

    private record Run(long wallNs, long inLockNs) {
    }

    private static void meet(CyclicBarrier wave) {
        try {
            wave.await();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(e);
        } catch (BrokenBarrierException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * One worker's share of every wave: parcels base+id, base+id+N, ... (K of them). Returns ns
     * inside the lock when timed.
     */
    private static long worker(SortPlan plan, Options o, int id, int n, boolean timed, CyclicBarrier wave) {
        long inLockNs = 0;
        long[] weight = new long[(int) o.roundParcels()];
        for (long base = 0; base < o.batch(); base += n * o.roundParcels()) {
            for (int j = 0; j < weight.length; j++) { // parallel part
                weight[j] = scanWork(base + id + (long) j * n, o.parallelIters());
            }
            if (o.phased()) {
                meet(wave); // nobody commits while anyone is still scanning
            }
            for (long w : weight) { // serial part: one lock section per parcel
                synchronized (plan) {
                    if (timed) {
                        long t0 = System.nanoTime();
                        plan.update(w, o.lockIters());
                        inLockNs += System.nanoTime() - t0;
                    } else {
                        plan.update(w, o.lockIters());
                    }
                }
            }
            if (o.phased()) {
                meet(wave); // nobody scans the next wave while anyone is still committing
            }
        }
        return inLockNs;
    }

    private static Run runBatch(SortPlan plan, Options o, int n, boolean timed) throws InterruptedException {
        plan.reset();
        long[] lockNs = new long[n];
        CyclicBarrier wave = new CyclicBarrier(n);
        List<Thread> pool = new ArrayList<>(n);
        long t0 = System.nanoTime();
        for (int id = 0; id < n; id++) {
            int me = id;
            pool.add(Thread.ofPlatform().name("worker-" + id)
                    .start(() -> lockNs[me] = worker(plan, o, me, n, timed, wave)));
        }
        for (Thread t : pool) {
            t.join(); // join is the happens-before edge to lockNs and the table
        }
        long wall = System.nanoTime() - t0;
        long inLock = 0;
        for (long v : lockNs) {
            inLock += v;
        }
        return new Run(wall, inLock);
    }

    private Amdahl() {
    }

    public static void main(String[] args) throws IOException, InterruptedException {
        Options o;
        try {
            o = Options.parse(args);
        } catch (IllegalArgumentException e) {
            System.err.println("amdahl-java: " + e.getMessage());
            System.exit(2);
            return;
        }
        if (!LatencyRecorder.profileConfigured()) {
            System.err.println("amdahl-java: " + LatencyRecorder.PROFILE_ENV + " is not set");
            System.exit(2);
        }
        for (int n : WORKERS) {
            if (o.batch() % (n * o.roundParcels()) != 0) {
                System.err.println("amdahl-java: --batch must be a multiple of N x --round-parcels for N=" + n);
                System.exit(2);
            }
        }
        String tag = o.phased() ? "amdahl" : "amdahl-free";
        Files.createDirectories(o.reportDir());
        SortPlan plan = new SortPlan();

        // JIT warm-up (not recorded): enough batches that scanWork and update run compiled.
        for (int i = 0; i < o.warmup(); i++) {
            for (int n : WORKERS) {
                runBatch(plan, o, n, false);
            }
            runBatch(plan, o, 1, true);
        }
        runBatch(plan, o, 1, false);
        long reference = plan.checksum();

        // Serial fraction s = time inside the lock / wall time, at N = 1: ratio of sums.
        long lockTotal = 0;
        long wallTotal = 0;
        for (int i = 0; i < o.calibrationRuns(); i++) {
            Run r = runBatch(plan, o, 1, true);
            lockTotal += r.inLockNs();
            wallTotal += r.wallNs();
        }
        double s = (double) lockTotal / wallTotal;
        System.out.printf("amdahl-java: batch %d parcels, serial fraction s = %.4f (time in lock / wall, N=1, "
                + "%d instrumented runs); ideal limit 1/s = %.2fx%n", o.batch(), s, o.calibrationRuns(), 1.0 / s);

        // Repetitions are interleaved (N=1, 2, 4, N=1, 2, 4, ...) so a change in background load
        // during the run lands on every N alike.
        int[] ws = WORKERS;
        List<LatencyRecorder> recs = new ArrayList<>();
        for (int n : ws) {
            recs.add(LatencyRecorder.singleThreaded(o.example(), tag + "-n" + n));
        }
        for (int i = 0; i < o.reps(); i++) {
            for (int k = 0; k < ws.length; k++) {
                Run r = runBatch(plan, o, ws[k], false);
                if (plan.checksum() != reference) {
                    throw new IllegalStateException("N=" + ws[k] + ": sort-plan table differs from the one-worker table");
                }
                recs.get(k).record(r.wallNs());
            }
        }
        long p50One = recs.get(0).histogram().getValueAtPercentile(50);
        for (int k = 0; k < ws.length; k++) {
            int n = ws[k];
            long p50 = recs.get(k).histogram().getValueAtPercentile(50);
            double predicted = Model.amdahlSpeedup(s, n);
            double measured = (double) p50One / p50;
            Map<String, Object> model = new LinkedHashMap<>();
            model.put("law", "Amdahl: S(N) = 1 / ((1 - p) + p / N), p = 1 - s");
            model.put("workers", n);
            model.put("serial_fraction_modelling_input", s);
            model.put("serial_fraction_basis", "time inside the lock / wall time, one worker, instrumented runs");
            model.put("predicted_speedup", predicted);
            model.put("measured_speedup_p50", measured);
            model.put("relative_error", (measured - predicted) / predicted);
            model.put("wall_p50_ns_n1", p50One);
            model.put("wall_p50_ns", p50);
            model.put("batch_parcels", o.batch());
            model.put("lock", "synchronized (platform threads)");
            model.put("sync", o.phased() ? "phased: barriers between the parallel and serial parts of a wave"
                    : "free: no barriers");
            model.put("parcels_per_worker_per_wave", o.roundParcels());
            Path report = o.reportDir().resolve("java-" + tag + "-n" + n + ".json");
            recs.get(k).writeReport(report, o.reps() + " repetitions after " + o.warmup()
                    + " warm-up rounds; wall time of the whole batch incl. thread start; repetitions interleaved across N; sync=" + (o.phased() ? "phased" : "free"), model);
            recs.get(k).printSummary();
            System.out.printf("  N=%d: predicted %.2fx, measured %.2fx (p50 wall %.1f ms), error %+.1f%%%n",
                    n, predicted, measured, p50 / 1e6, (measured - predicted) / predicted * 100.0);
        }
    }
}
