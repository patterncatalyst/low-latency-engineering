package io.patterncatalyst.lowlat.eliminating;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;
import java.util.concurrent.locks.LockSupport;
import net.openhft.affinity.AffinityLock;

/**
 * Five camera threads bump their own counters while a telemetry thread samples them (the Java lane of the
 * false-sharing experiment). Each thread pins itself to its CPU with {@link AffinityLock}, records the time of
 * every batch of {@value #BATCH} increments into its own array, and after the run all threads stay parked while
 * the placement lines are printed and held, so verify.sh can check {@code /proc}.
 *
 * <p>Variants: {@code adjacent-counters}, {@code pair-padded}, {@code line-padded}, {@code smt-siblings}
 * (adjacent layout, two cameras on one core's hardware threads), and {@code long-adder} (observed): the JDK's
 * {@link LongAdder} shared by all cameras, a different shape (one contended sum, not one value per camera) that
 * stripes and pads internally. {@code --increment rmw} swaps the single-writer store for {@code getAndAdd}.
 */
final class CountersRun {

    static final int BATCH = 1_000;
    private static final int NO_READ_EVERY = 32;
    private static final String EXAMPLE = "09-eliminating-work";

    private CountersRun() {
    }

    private record Options(String variant, List<Integer> cpus, int cameras, int batches, int holdMs, boolean rmw, Path out) {
    }

    private static Options parse(List<String> args) {
        String variant = null;
        List<Integer> cpus = new ArrayList<>();
        int cameras = CameraCounters.CAMERAS;
        int batches = 20_000;
        int holdMs = 0;
        boolean rmw = false;
        Path out = null;
        for (int i = 0; i < args.size(); i++) {
            String a = args.get(i);
            switch (a) {
                case "--variant" -> variant = args.get(++i);
                case "--adjacent-counters", "--line-padded", "--smt-siblings" -> variant = a.substring(2);
                case "--cpus" -> {
                    for (String c : args.get(++i).split(",")) {
                        cpus.add(Integer.parseInt(c));
                    }
                }
                case "--cameras" -> cameras = Integer.parseInt(args.get(++i));
                case "--batches" -> batches = Integer.parseInt(args.get(++i));
                case "--hold-ms" -> holdMs = Integer.parseInt(args.get(++i));
                case "--increment" -> rmw = switch (args.get(++i)) {
                    case "store" -> false;
                    case "rmw" -> true;
                    default -> throw new IllegalArgumentException("--increment must be store or rmw");
                };
                case "--out" -> out = Path.of(args.get(++i));
                default -> throw new IllegalArgumentException("unknown option " + a);
            }
        }
        if (variant == null || !List.of("adjacent-counters", "pair-padded", "line-padded", "smt-siblings", "long-adder").contains(variant)) {
            throw new IllegalArgumentException("--variant must be adjacent-counters, pair-padded, line-padded, smt-siblings or long-adder");
        }
        if (cameras < 1 || cameras > CameraCounters.CAMERAS || cpus.size() != cameras + 1) {
            throw new IllegalArgumentException("--cpus needs one CPU per camera (1 to 5) plus one for telemetry");
        }
        if (out == null) {
            throw new IllegalArgumentException("--out FILE is required");
        }
        return new Options(variant, cpus, cameras, batches, holdMs, rmw, out);
    }

    static int run(List<String> args) throws IOException, InterruptedException {
        Options o;
        try {
            o = parse(args);
        } catch (IllegalArgumentException e) {
            System.err.println("counters: " + e.getMessage());
            System.err.println("usage: counters --variant NAME --cpus C0,..,TELEMETRY --out FILE [--cameras N] [--batches N] "
                    + "[--hold-ms MS] [--increment store|rmw]");
            return 2;
        }
        CameraCounters.Layout layout = switch (o.variant) {
            case "pair-padded" -> CameraCounters.Layout.PAIR_PADDED;
            case "line-padded" -> CameraCounters.Layout.LINE_PADDED;
            default -> CameraCounters.Layout.ADJACENT;
        };
        CameraCounters counters = new CameraCounters(layout);
        LongAdder adder = new LongAdder(); // the long-adder variant: every camera adds to this one sum
        boolean useAdder = o.variant.equals("long-adder");
        long[][] batchNs = new long[o.cameras][o.batches];
        String[] placed = new String[o.cameras + 1];

        CountDownLatch ready = new CountDownLatch(o.cameras + 1);
        CountDownLatch go = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(o.cameras);
        AtomicBoolean release = new AtomicBoolean();
        AtomicBoolean stopTelemetry = new AtomicBoolean();
        AtomicLong telemetrySamples = new AtomicLong();
        List<Thread> threads = new ArrayList<>();

        for (int c = 0; c < o.cameras; c++) {
            int camera = c;
            Thread t = new Thread(() -> {
                try (AffinityLock lock = Placement.acquire(o.cpus.get(camera))) {
                    placed[camera] = Placement.line(lock.cpuId(), "camera");
                    warmUp(layout, camera, o.rmw, useAdder);
                    ready.countDown();
                    go.await();
                    Batch batch = o.variant.equals("long-adder") ? Batch.ADDER : o.rmw ? Batch.RMW : Batch.STORE;
                    timeBatches(batch, counters, adder, camera, batchNs[camera]);
                    done.countDown();
                    while (!release.get()) { // parked, so verify.sh can read where this thread last ran
                        LockSupport.parkNanos(10_000_000L);
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }, "camera-" + camera);
            threads.add(t);
            t.start();
        }
        Thread telemetry = new Thread(() -> {
            try (AffinityLock lock = Placement.acquire(o.cpus.get(o.cameras))) {
                placed[o.cameras] = Placement.line(lock.cpuId(), "telemetry");
                ready.countDown();
                long sink = 0;
                while (!stopTelemetry.get()) {
                    for (int c = 0; c < o.cameras; c++) {
                        sink += useAdder ? adder.sum() : counters.total(c);
                    }
                    telemetrySamples.incrementAndGet();
                    LockSupport.parkNanos(1_000_000L);
                }
                while (!release.get()) {
                    LockSupport.parkNanos(10_000_000L);
                }
                if (sink == 1) {
                    System.out.print("");
                }
            }
        }, "telemetry");
        threads.add(telemetry);
        telemetry.start();

        ready.await();
        PerfRegion perf = PerfRegion.open();
        perf.enable();
        go.countDown();
        done.await();
        perf.disable();
        stopTelemetry.set(true);
        for (String line : placed) {
            Placement.announce(line);
        }
        if (o.holdMs > 0) {
            Thread.sleep(o.holdMs);
        }
        release.set(true);
        for (Thread t : threads) {
            t.join();
        }

        long perCamera = (long) o.batches * BATCH;
        if (useAdder) {
            if (adder.sum() != perCamera * o.cameras) {
                throw new IllegalStateException("the adder lost increments");
            }
        } else {
            for (int c = 0; c < o.cameras; c++) {
                if (counters.total(c) != perCamera) {
                    throw new IllegalStateException("camera " + c + " lost increments");
                }
            }
        }
        LatencyRecorder recorder = LatencyRecorder.singleThreaded(EXAMPLE, "counters-" + o.variant);
        for (long[] perThread : batchNs) {
            for (long ns : perThread) {
                recorder.record(ns);
            }
        }
        boolean siblings = o.variant.equals("smt-siblings");
        Map<String, Object> runtime = new LinkedHashMap<>(RuntimeInfo.jvm());
        Map<String, Long> exact = new LinkedHashMap<>();
        exact.put("cameras", (long) o.cameras);
        exact.put("batch_size", (long) BATCH);
        exact.put("batches_per_camera", (long) o.batches);
        exact.put("increments", perCamera * o.cameras);
        exact.put("stride_bytes", useAdder ? 0L : layout.cameraStride());
        exact.put("telemetry_samples", telemetrySamples.get());
        runtime.put("counters", RuntimeInfo.counters(exact));
        runtime.put("placement", RuntimeInfo.placement(o.cpus, !siblings, siblings));
        PerfRegion.reportOps(perCamera * o.cameras);
        recorder.printSummary();
        recorder.writeReport(o.out, "op=counters; one sample = one batch of " + BATCH + " increments by one camera thread ("
                + o.cameras + " cameras, each thread pinned; increment=" + (useAdder ? "LongAdder.increment" : o.rmw ? "getAndAdd" : "single-writer plain read + release store")
                + "); a telemetry thread samples every camera about once per millisecond"
                + (useAdder ? "; one shared LongAdder instead of per-camera counters" : ""), null, runtime);
        System.out.println("report: " + o.out);
        return 0;
    }

    private static final long WARM_UP_NANOS = 600_000_000L;

    /**
     * Runs the camera's own loop on a scratch counter set until the JIT has compiled it, before the counted region
     * starts: the whole measured run is tens of milliseconds, the same order as the compilation, so unwarmed code
     * would put the compiler threads' cache misses into the hardware counts.
     */
    private static void warmUp(CameraCounters.Layout layout, int camera, boolean rmw, boolean useAdder) {
        CameraCounters scratch = new CameraCounters(layout);
        LongAdder scratchAdder = new LongAdder();
        Batch batch = useAdder ? Batch.ADDER : rmw ? Batch.RMW : Batch.STORE;
        long[] scratchNs = new long[WARM_UP_BATCHES];
        long end = System.nanoTime() + WARM_UP_NANOS;
        while (System.nanoTime() < end) {
            timeBatches(batch, scratch, scratchAdder, camera, scratchNs);
        }
    }

    private static final int WARM_UP_BATCHES = 64;

    /** The measured loop: one timed batch per element of {@code batchNs}. Warmed whole, so it runs C2 code. */
    private static void timeBatches(Batch batch, CameraCounters counters, LongAdder adder, int camera, long[] batchNs) {
        for (int b = 0; b < batchNs.length; b++) {
            long t0 = System.nanoTime();
            batch.run(counters, adder, camera);
            batchNs[b] = System.nanoTime() - t0;
        }
    }

    /** One batch of {@value #BATCH} increments by one camera; one loop per increment so the loop body stays small. */
    private enum Batch {
        /** Single writer: a plain read and a release store, no read-modify-write. */
        STORE {
            @Override
            void run(CameraCounters counters, LongAdder adder, int camera) {
                for (int i = 0; i < BATCH; i++) {
                    if ((i & (NO_READ_EVERY - 1)) == NO_READ_EVERY - 1) {
                        counters.bumpNoRead(camera);
                    } else {
                        counters.bumpRead(camera);
                    }
                }
            }
        },
        /** The same counts as an atomic read-modify-write. */
        RMW {
            @Override
            void run(CameraCounters counters, LongAdder adder, int camera) {
                for (int i = 0; i < BATCH; i++) {
                    if ((i & (NO_READ_EVERY - 1)) == NO_READ_EVERY - 1) {
                        counters.addNoRead(camera);
                    } else {
                        counters.addRead(camera);
                    }
                }
            }
        },
        /** Every camera adds to one shared sum. */
        ADDER {
            @Override
            void run(CameraCounters counters, LongAdder adder, int camera) {
                for (int i = 0; i < BATCH; i++) {
                    adder.increment();
                }
            }
        };

        abstract void run(CameraCounters counters, LongAdder adder, int camera);
    }
}
