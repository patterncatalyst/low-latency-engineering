package io.patterncatalyst.lowlat.lockfree;

import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.BrokenBarrierException;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.atomic.AtomicReference;
import net.openhft.affinity.Affinity;

/**
 * Thread placement for the Ch10 measurements. It is an experiment control, not isolation: an OpenHFT
 * Affinity call pins each of our own threads to a CPU from {@code --cpus} (distinct physical cores),
 * which needs no privilege and changes nothing on the host. A run records where its threads ran
 * ({@code runtime.placement}) and a script checks the pins from {@code /proc}.
 */
final class Placement {

    private static final Path SYS_CPU = Path.of("/sys/devices/system/cpu");

    private Placement() {
    }

    /** {@code "0,2,4"} to {@code [0, 2, 4]}. */
    static List<Integer> parseCpus(String csv) {
        List<Integer> cpus = new ArrayList<>();
        for (String part : csv.split(",")) {
            try {
                int cpu = Integer.parseInt(part.strip());
                if (cpu < 0) {
                    throw new IllegalArgumentException("--cpus: negative CPU " + part);
                }
                cpus.add(cpu);
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("--cpus: '" + part + "' is not a CPU number", e);
            }
        }
        return cpus;
    }

    /**
     * {@code runtime.placement}: the pinned CPUs, whether they sit on distinct physical cores and
     * whether any two are SMT siblings, from sysfs topology. Empty when nothing was pinned.
     */
    static Map<String, Object> placement(List<Integer> cpus) {
        List<Integer> pinned = cpus.stream().filter(cpu -> cpu >= 0).toList();
        if (pinned.isEmpty()) {
            return Map.of();
        }
        Set<String> cores = new HashSet<>();
        boolean siblings = false;
        for (int cpu : pinned) {
            siblings |= !cores.add(coreOf(cpu));
        }
        return RuntimeInfo.placement(pinned, !siblings, siblings);
    }

    private static String coreOf(int cpu) {
        Path topology = SYS_CPU.resolve("cpu" + cpu).resolve("topology");
        return read(topology.resolve("physical_package_id"), "0") + ":" + read(topology.resolve("core_id"), Integer.toString(cpu));
    }

    private static String read(Path file, String fallback) {
        try {
            return Files.readString(file).strip();
        } catch (IOException e) {
            return fallback;
        }
    }

    /** An uncaught-exception handler that keeps the first failure for the coordinating thread and prints it at once. */
    static Thread.UncaughtExceptionHandler recordTo(AtomicReference<Throwable> failure) {
        return (thread, error) -> {
            System.err.println("thread " + thread.getName() + " failed: " + error);
            error.printStackTrace();
            failure.compareAndSet(null, error);
        };
    }

    /** The calling thread's voluntary and involuntary context switches so far, from {@code /proc/thread-self/status}. */
    static long[] ctxSwitches() {
        long voluntary = 0;
        long involuntary = 0;
        try {
            for (String line : Files.readAllLines(Path.of("/proc/thread-self/status"))) {
                if (line.startsWith("voluntary_ctxt_switches:")) {
                    voluntary = Long.parseLong(line.substring(line.indexOf(':') + 1).strip());
                } else if (line.startsWith("nonvoluntary_ctxt_switches:")) {
                    involuntary = Long.parseLong(line.substring(line.indexOf(':') + 1).strip());
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException("cannot read /proc/thread-self/status", e);
        }
        return new long[] {voluntary, involuntary};
    }

    /**
     * The calling thread's pin: OpenHFT {@code Affinity.setAffinity(cpu)} (sched_setaffinity on this
     * thread), confirmed against the CPU the thread then runs on, and undone on close. The
     * higher-level {@code AffinityLock} would also work, but its inventory reserves CPU 0 for the
     * operating system, and the lowest-numbered CPU of the first core is one of ours to pin to.
     */
    static final class Pin implements AutoCloseable {
        private final boolean pinned;

        Pin(int cpu) {
            this.pinned = cpu >= 0;
            if (pinned) {
                Affinity.setAffinity(cpu);
                Thread.yield(); // the thread migrates when it is next scheduled
                int on = Affinity.getCpu();
                if (on != cpu) {
                    Affinity.resetToBaseAffinity();
                    throw new IllegalStateException("pinned to CPU " + cpu + " but running on CPU " + on);
                }
            }
        }

        @Override
        public void close() {
            if (pinned) {
                Affinity.resetToBaseAffinity();
            }
        }
    }

    /**
     * The start of a pinned run. Each of {@code workers} threads calls {@link #workerReady} first: it
     * pins itself and waits. The coordinating thread calls {@link #release}, which waits for all of
     * them, prints one {@code pinned pid=P tid=T cpu=C role=R} line per thread and
     * {@code placement-ready}, holds for {@code holdMs} (a script checks every thread's CPU in
     * {@code /proc} meanwhile) and lets the workers go together.
     */
    static final class Gate {
        private final CyclicBarrier barrier;
        private final long holdMs;
        private final boolean announce;
        private final List<String> lines = new ArrayList<>(); // guarded by itself

        Gate(int workers, long holdMs) {
            this(workers, holdMs, true);
        }

        /** {@code announce} false keeps the "pinned" and "placement-ready" lines off the console (a warm-up pass). */
        Gate(int workers, long holdMs, boolean announce) {
            this.barrier = new CyclicBarrier(workers + 1);
            this.holdMs = holdMs;
            this.announce = announce;
        }

        /**
         * Worker thread. Returns the pin (close it when the thread is done); a {@code cpu} of -1
         * skips the pin (unit tests).
         */
        Pin workerReady(int cpu, String role) {
            Pin pin = new Pin(cpu);
            try {
                synchronized (lines) {
                    lines.add("pinned pid=" + ProcessHandle.current().pid() + " tid=" + Affinity.getThreadId() + " cpu="
                            + (cpu >= 0 ? Affinity.getCpu() : -1) + " role=" + role);
                }
            } catch (RuntimeException e) {
                barrier.reset();
                pin.close();
                throw e;
            }
            await();
            await();
            return pin;
        }

        /** Coordinating thread; every worker's pin is in place by the time it returns. */
        void release() throws InterruptedException {
            await();
            if (announce) {
                synchronized (lines) {
                    lines.forEach(System.out::println);
                }
                System.out.println("placement-ready");
                System.out.flush();
            }
            Thread.sleep(holdMs);
            await();
        }

        private void await() {
            try {
                barrier.await();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("interrupted while waiting for the start", e);
            } catch (BrokenBarrierException e) {
                throw new IllegalStateException("another thread failed before the start", e);
            }
        }
    }
}
