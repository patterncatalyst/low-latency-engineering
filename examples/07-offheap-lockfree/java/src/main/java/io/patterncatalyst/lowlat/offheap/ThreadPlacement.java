package io.patterncatalyst.lowlat.offheap;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import net.openhft.affinity.Affinity;
import net.openhft.affinity.AffinityLock;

/**
 * Where the decide thread runs. The hand-off structures start their consumer through
 * {@link #wrap}, so a placement that pins the thread to a CPU wraps the thread body in a lock
 * held for its lifetime and nothing else changes.
 *
 * <p>Two placements. {@link #UNPINNED} is the scheduler's choice and the only one the host part
 * uses: pinning proves nothing without an isolated CPU to pin to, and isolating a CPU is a change
 * to the machine. {@link #PINNED_ISOLATED} is the VM part's: it binds the thread to guest CPU 3,
 * which the guest kernel boots with {@code isolcpus=3 nohz_full=3 rcu_nocbs=3}.
 */
public enum ThreadPlacement {

    /** The scheduler decides. */
    UNPINNED("unpinned") {
        @Override
        public Runnable wrap(Runnable body) {
            return body;
        }
    },

    /**
     * An OpenHFT Affinity lock on CPU {@value #ISOLATED_CPU}, held until the thread body returns.
     * It fails loudly when the kernel was not booted with {@code isolcpus=3} (checked here, before
     * the thread exists) or when the lock does not land on CPU 3 (checked on the thread itself,
     * where it prints a {@code placement failed:} line and throws).
     */
    PINNED_ISOLATED("pinned-isolated") {
        @Override
        public Runnable wrap(Runnable body) {
            requireIsolatedCpu(Path.of("/proc/cmdline"), ISOLATED_CPU);
            return () -> {
                try (AffinityLock lock = AffinityLock.acquireLock(ISOLATED_CPU)) {
                    int cpu = Affinity.getCpu();
                    if (cpu != ISOLATED_CPU || lock.cpuId() != ISOLATED_CPU || !lock.isBound()) {
                        String why = "the lock is on CPU " + lock.cpuId() + " (bound " + lock.isBound() + "), the thread runs on CPU " + cpu
                                + ", wanted CPU " + ISOLATED_CPU;
                        System.err.println("placement failed: " + why);
                        throw new IllegalStateException("pinned-isolated: " + why);
                    }
                    body.run();
                }
            };
        }
    };

    /** The CPU the isolated guest profile (scripts/lab/guest-profiles/isolate-cpu3.conf) reserves. */
    public static final int ISOLATED_CPU = 3;

    private final String label;

    ThreadPlacement(String label) {
        this.label = label;
    }

    /** The placement for {@code name}, as given to {@code --placement}. */
    public static ThreadPlacement named(String name) {
        for (ThreadPlacement placement : values()) {
            if (placement.label.equals(name)) {
                return placement;
            }
        }
        throw new IllegalArgumentException("--placement: unpinned | pinned-isolated, got " + name);
    }

    /**
     * Fails unless the kernel command line in {@code cmdline} names {@code cpu} in an {@code isolcpus=}
     * argument (a list or range, optionally after flags such as {@code domain,managed_irq,}).
     */
    static void requireIsolatedCpu(Path cmdline, int cpu) {
        String line;
        try {
            line = Files.readString(cmdline).strip();
        } catch (IOException e) {
            throw new IllegalStateException("pinned-isolated: cannot read " + cmdline, e);
        }
        if (!isolates(line, cpu)) {
            throw new IllegalStateException("pinned-isolated: " + cmdline + " has no isolcpus=" + cpu
                    + " (boot the isolated guest profile, snapshot lab-ready-iso): " + line);
        }
    }

    /** Whether some {@code isolcpus=} argument of the command line {@code line} covers {@code cpu}. */
    static boolean isolates(String line, int cpu) {
        for (String arg : line.split("\\s+")) {
            if (!arg.startsWith("isolcpus=")) {
                continue;
            }
            for (String item : arg.substring("isolcpus=".length()).split(",")) {
                String[] range = item.split("-", 2);
                try {
                    int lo = Integer.parseInt(range[0]);
                    int hi = range.length == 2 ? Integer.parseInt(range[1]) : lo;
                    if (lo <= cpu && cpu <= hi) {
                        return true;
                    }
                } catch (NumberFormatException flag) {
                    // a flag such as "domain" or "managed_irq", not a CPU list item
                }
            }
        }
        return false;
    }

    /** The name shown in the report notes. */
    public String label() {
        return label;
    }

    /** The body the decide thread runs: {@code body} itself, or {@code body} inside whatever the placement holds. */
    public abstract Runnable wrap(Runnable body);
}
