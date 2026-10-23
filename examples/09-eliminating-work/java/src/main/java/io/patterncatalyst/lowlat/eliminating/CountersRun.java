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
        int stride = switch (o.variant) {
            case "pair-padded" -> CameraCounters.PAIR_PADDED;
            case "line-padded" -> CameraCounters.LINE_PADDED;
            default -> CameraCounters.ADJACENT;
        };
        CameraCounters counters = new CameraCounters(stride);
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
                    ready.countDown();
                    go.await();
                    for (int b = 0; b < o.batches; b++) {
                        long t0 = System.nanoTime();
                        for (int i = 0; i < BATCH; i++) {
                            if (useAdder) {
                                adder.increment();
                            } else {
                                bump(counters, camera, i % NO_READ_EVERY == NO_READ_EVERY - 1, o.rmw);
                            }
                        }
                        batchNs[camera][b] = System.nanoTime() - t0;
                    }
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
        exact.put("stride_bytes", useAdder ? 0L : stride * 8L);
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

    private static void bump(CameraCounters counters, int camera, boolean noRead, boolean rmw) {
        if (rmw) {
            if (noRead) {
                counters.addNoRead(camera);
            } else {
                counters.addRead(camera);
            }
        } else if (noRead) {
            counters.bumpNoRead(camera);
        } else {
            counters.bumpRead(camera);
        }
    }
}
