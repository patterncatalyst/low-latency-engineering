package io.patterncatalyst.lowlat.ch15;

import java.util.BitSet;
import net.openhft.affinity.Affinity;

/**
 * Moves the calling thread to one CPU. Ch7 pinned its decide thread with OpenHFT Java-Thread-Affinity, so this
 * chapter uses the same library instead of a second hand-written JNA mapping of {@code sched_setaffinity}.
 * (Chapter 14 does use JNA directly, for the scheduling policy, which Affinity does not cover.)
 */
public final class HotThread {

    private HotThread() {
    }

    /** Restricts the calling thread to {@code cpu} and checks the kernel agrees. */
    public static void pinTo(int cpu) {
        BitSet only = new BitSet();
        only.set(cpu);
        Affinity.setAffinity(only);
        BitSet now = Affinity.getAffinity();
        if (!now.equals(only)) {
            throw new IllegalStateException("asked for CPU " + cpu + ", thread affinity is " + CpuLists.format(now));
        }
    }

    /** The CPUs the calling thread may run on. */
    public static BitSet allowed() {
        return Affinity.getAffinity();
    }

    /** The CPU the calling thread is running on right now. */
    public static int currentCpu() {
        return Affinity.getCpu();
    }
}
