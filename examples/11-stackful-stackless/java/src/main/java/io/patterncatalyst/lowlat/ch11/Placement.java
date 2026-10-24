package io.patterncatalyst.lowlat.ch11;

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
import net.openhft.affinity.Affinity;

/**
 * Thread placement for the Ch11 measurements (adapted from example 10). It is an experiment control, not
 * isolation: an OpenHFT Affinity call pins a thread to a CPU from {@code --cpus} (distinct physical cores),
 * which needs no privilege and changes nothing on the host. A run records where its threads ran
 * ({@code runtime.placement}) and verify.sh checks the pins from {@code /proc}. Called from a virtual thread,
 * the pin lands on the carrier thread that is running it.
 */
final class Placement {

    private static final Path SYS_CPU = Path.of("/sys/devices/system/cpu");

    private Placement() {
    }

    /** Loads the Affinity class on the calling thread so its base mask is the process's, not a pinned thread's. */
    static void captureBaseAffinity() {
        Affinity.getAffinity();
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

    /** {@code runtime.placement} for the pinned CPUs (those at or above 0), or an empty map when nothing was pinned. */
    static Map<String, Object> placement(List<Integer> cpus) {
        List<Integer> pinned = cpus.stream().filter(cpu -> cpu >= 0).distinct().toList();
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

    /** The calling thread's voluntary and involuntary context switches, from {@code /proc/thread-self/status}. */
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

    /** The calling thread's pin: Affinity.setAffinity(cpu), confirmed against the CPU the thread then runs on, undone on close. */
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
     * The start of a pinned run. Each of {@code workers} threads calls {@link #workerReady} first: it pins
     * itself and waits. The coordinating thread calls {@link #release}, which waits for all of them, prints
     * one {@code pinned pid=P tid=T cpu=C role=R} line per pinned thread and {@code placement-ready}, holds for
     * {@code holdMs} (verify.sh checks every thread's CPU in {@code /proc} meanwhile), prints {@code released}
     * and lets the workers go together. Each worker stamps {@code System.nanoTime()} as it leaves the gate;
     * {@link #startSkewNs} is the spread of those stamps.
     */
    static final class Gate {
        private final CyclicBarrier barrier;
        private final long holdMs;
        private final boolean announce;
        private final List<String> lines = new ArrayList<>(); // guarded by itself
        private final List<Long> left = new ArrayList<>(); // guarded by lines

        Gate(int workers, long holdMs, boolean announce) {
            this.barrier = new CyclicBarrier(workers + 1);
            this.holdMs = holdMs;
            this.announce = announce;
        }

        /** Worker thread. Returns the pin (close it when the thread is done); a {@code cpu} of -1 skips the pin. */
        Pin workerReady(int cpu, String role) {
            Pin pin = new Pin(cpu);
            try {
                if (cpu >= 0) {
                    synchronized (lines) {
                        lines.add("pinned pid=" + ProcessHandle.current().pid() + " tid=" + Affinity.getThreadId() + " cpu="
                                + Affinity.getCpu() + " role=" + role);
                    }
                }
            } catch (RuntimeException e) {
                barrier.reset();
                pin.close();
                throw e;
            }
            await();
            await();
            long now = System.nanoTime();
            synchronized (lines) {
                left.add(now);
            }
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
            if (announce) {
                System.out.println("released");
                System.out.flush();
            }
            await();
        }

        /** Latest minus earliest worker stamp after the release (0 for fewer than two workers). */
        long startSkewNs() {
            synchronized (lines) {
                if (left.size() < 2) {
                    return 0;
                }
                return left.stream().mapToLong(Long::longValue).max().orElse(0) - left.stream().mapToLong(Long::longValue).min().orElse(0);
            }
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
