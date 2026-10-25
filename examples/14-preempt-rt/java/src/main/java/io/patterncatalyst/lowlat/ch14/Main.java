package io.patterncatalyst.lowlat.ch14;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The Java lane of Ch14: a periodic wake-up on a SCHED_FIFO thread, beside a thread that allocates.
 *
 * <p>A real-time kernel bounds what the kernel adds to a wake-up. It does not stop the JVM from pausing every
 * Java thread at a safepoint, and a pause that long shows up as late wakes whatever the kernel's preemption
 * model is. Run it with {@code -Xlog:safepoint:file=...} to line the late wakes up with the pauses.
 *
 * <pre>
 * Main --cpu N [--alloc-cpu N] [--seconds S] [--warmup-seconds S] [--period-us US] [--priority 1..99]
 *      [--env vm] [--guest-profile SNAPSHOT/PROFILE] [--example ID] [--variant NAME] [--report FILE]
 * </pre>
 *
 * <p>Only the hot thread is SCHED_FIFO (through JNA, see {@link Sched}); every other thread in the JVM stays
 * SCHED_OTHER. The hot thread prints {@code hot-thread tid=N ...} once its policy is set, so a driver can run
 * {@code chrt -p N} on it while the run is going.
 */
public final class Main {

    private static final Set<String> OPTIONS = Set.of("cpu", "alloc-cpu", "seconds", "warmup-seconds", "period-us",
            "priority", "env", "guest-profile", "example", "variant", "report");
    private static final String USAGE = "usage: Main --cpu N [--alloc-cpu N] [--seconds S] [--warmup-seconds S] "
            + "[--period-us US] [--priority 1..99] [--env vm] [--guest-profile S] [--example ID] [--variant NAME] [--report FILE]";

    private Main() {
    }

    /** Parsed options; an unknown option is an error, so a misspelling cannot run with the default. */
    record Options(Map<String, String> values) {

        static Options parse(String[] args) {
            Map<String, String> values = new java.util.HashMap<>();
            for (int i = 0; i < args.length; i++) {
                String key = args[i];
                if (!key.startsWith("--") || !OPTIONS.contains(key.substring(2))) {
                    throw new IllegalArgumentException("unknown option '" + key + "'\n" + USAGE);
                }
                if (i + 1 >= args.length) {
                    throw new IllegalArgumentException(key + " needs a value");
                }
                values.put(key.substring(2), args[++i]);
            }
            return new Options(values);
        }

        String get(String key, String fallback) {
            return values.getOrDefault(key, fallback);
        }

        int integer(String key, int fallback) {
            String text = get(key, Integer.toString(fallback));
            try {
                return Integer.parseInt(text);
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("--" + key + ": '" + text + "' is not a number");
            }
        }
    }

    public static void main(String[] args) throws Exception {
        Options o;
        try {
            o = Options.parse(args);
            if (!o.values().containsKey("cpu")) {
                throw new IllegalArgumentException("--cpu is required (the hot thread is pinned; not CPU 0, the housekeeping CPU)");
            }
        } catch (IllegalArgumentException e) {
            System.err.println("Main: " + e.getMessage());
            System.exit(2);
            return;
        }
        int cpu = o.integer("cpu", -1);
        int allocCpu = o.integer("alloc-cpu", -1);
        int priority = o.integer("priority", 95);
        long periodNanos = o.integer("period-us", 1000) * 1_000L;
        long seconds = o.integer("seconds", 5);
        long warmupSeconds = o.integer("warmup-seconds", 1);
        if (cpu == 0) {
            System.err.println("Main: --cpu 0 is the housekeeping CPU (sshd runs there); pick another CPU");
            System.exit(2);
        }

        LatencyRecorder recorder = LatencyRecorder.singleThreaded(o.get("example", "14-preempt-rt"), o.get("variant", "java-wake"));
        AtomicReference<PeriodicWake.Result> result = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();

        Thread hot = new Thread(() -> {
            try {
                Sched.pin(cpu);
                Sched.fifo(priority);
                if (Sched.policy() != Libc.SCHED_FIFO) {
                    throw new IllegalStateException("the hot thread is not SCHED_FIFO after sched_setscheduler");
                }
                System.out.println("hot-thread tid=" + Sched.tid() + " policy=SCHED_FIFO priority=" + priority + " cpu=" + cpu);
                System.out.flush();
                PeriodicWake wake = new PeriodicWake(periodNanos);
                wake.run(warmupSeconds * 1_000_000_000L, ns -> { });
                // A lateness of 0 ns cannot go in a histogram that starts at 1 ns.
                result.set(wake.run(seconds * 1_000_000_000L, ns -> recorder.record(Math.max(1L, ns))));
            } catch (Throwable t) {
                failure.set(t);
            }
        }, "hot-wake");

        AllocationLoad load = new AllocationLoad(allocCpu);
        Thread allocator = new Thread(load, "allocator");
        allocator.setDaemon(true);
        allocator.start();
        hot.start();
        hot.join();
        load.stop();
        allocator.join();

        if (failure.get() != null) {
            System.err.println("Main: " + failure.get());
            System.exit(1);
        }
        PeriodicWake.Result outcome = result.get();
        recorder.printSummary();
        System.out.println("samples=" + outcome.samples() + " missed_periods=" + outcome.missedPeriods());

        String path = o.get("report", "");
        if (!path.isEmpty()) {
            Map<String, Object> runtime = RuntimeInfo.jvm();
            runtime.put("placement", RuntimeInfo.placement(List.of(cpu), true, false));
            runtime.put("counters", RuntimeInfo.counters(Map.of("samples", outcome.samples(), "missed_periods", outcome.missedPeriods())));
            String envKind = o.get("env", "");
            if (!envKind.isEmpty()) {
                if (!envKind.equals("vm")) {
                    throw new IllegalArgumentException("--env: only vm is supported here, got '" + envKind + "'");
                }
                runtime.put("environment", RuntimeInfo.environment(RuntimeInfo.EnvKind.VM, o.get("guest-profile", null), null, null));
            }
            String notes = "clock=System.nanoTime abs-deadline parkNanos period_us=" + periodNanos / 1_000 + " policy=SCHED_FIFO priority="
                    + priority + " hot_cpu=" + cpu + " allocator_cpu=" + allocCpu + " allocated_mib=" + load.allocatedMib();
            recorder.writeReport(Path.of(path), notes, null, runtime);
            System.out.println("report: " + path);
        }
    }

    /**
     * A SCHED_OTHER thread that allocates and keeps some of it for a while, so the collector has young and old
     * work and the JVM reaches safepoints during the run. It is the defect the kernel can't fix.
     */
    static final class AllocationLoad implements Runnable {
        private static final int BLOCK_BYTES = 64 * 1024;
        private static final int RETAINED = 256;

        private final int cpu;
        private volatile boolean running = true;
        private volatile long blocks;

        AllocationLoad(int cpu) {
            this.cpu = cpu;
        }

        void stop() {
            running = false;
        }

        long allocatedMib() {
            return blocks * BLOCK_BYTES / (1024 * 1024);
        }

        @Override
        public void run() {
            if (cpu >= 0) {
                Sched.pin(cpu);
            }
            List<byte[]> keep = new ArrayList<>(RETAINED);
            long n = 0;
            while (running) {
                byte[] block = new byte[BLOCK_BYTES];
                block[(int) (n % BLOCK_BYTES)] = 1; // touch it, so the allocation is not removed
                if (keep.size() < RETAINED) {
                    keep.add(block);
                } else {
                    keep.set((int) (n % RETAINED), block);
                }
                blocks = ++n;
            }
        }
    }
}
