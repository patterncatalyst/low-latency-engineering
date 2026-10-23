package io.patterncatalyst.lowlat.offheap;

import java.lang.management.ManagementFactory;
import java.lang.management.MemoryPoolMXBean;
import java.lang.management.MemoryType;

/**
 * Old-generation occupancy after a full collection: the live data the collector has to carry for
 * as long as the program runs. A controlled measurement step, taken once when the run is over
 * and never on the hot path.
 */
final class OldGen {

    private OldGen() {
    }

    /**
     * Forces a collection and returns the bytes in use in the old-generation heap pool(s)
     * afterwards ("G1 Old Gen", "Tenured Gen" and the like). The explicit collection is the
     * point: a reading without one would include garbage the collector has not reached.
     */
    static long usedAfterGc() {
        System.gc();
        return ManagementFactory.getMemoryPoolMXBeans().stream()
                .filter(pool -> pool.getType() == MemoryType.HEAP)
                .filter(pool -> isOldGeneration(pool.getName()))
                .mapToLong(OldGen::used)
                .sum();
    }

    static boolean isOldGeneration(String poolName) {
        return poolName.contains("Old") || poolName.contains("Tenured");
    }

    private static long used(MemoryPoolMXBean pool) {
        return pool.getUsage().getUsed();
    }
}
