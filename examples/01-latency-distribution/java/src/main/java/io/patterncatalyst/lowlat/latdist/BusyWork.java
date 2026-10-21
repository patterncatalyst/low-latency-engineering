package io.patterncatalyst.lowlat.latdist;

/**
 * The slow "re-lookup" path: real CPU work calibrated to a target duration. A sleep would
 * yield the core and hide the cost; a busy loop holds it, as a real lookup does.
 */
final class BusyWork {

    /** Written by every {@link #spin}; the volatile store makes the loop's result observable to the JIT. */
    private static volatile long sink;

    private BusyWork() {
    }

    /** A dependent multiply-add chain: each step needs the previous result. */
    static long spin(long iterations) {
        long x = 0x9E3779B97F4A7C15L;
        for (long i = 0; i < iterations; i++) {
            x = x * 6364136223846793005L + 1442695040888963407L;
        }
        sink = x;
        return x;
    }

    /**
     * Iterations of {@link #spin} that take {@code targetUs}. Doubles the count until a run lasts
     * 20 ms, then times eight more runs and keeps the fastest: the early runs are interpreted or
     * C1-compiled (the JIT's C2 code is faster), and a run preempted on a busy host measures the
     * scheduler, not the loop.
     */
    static long calibrate(long targetUs) {
        long n = 1 << 12;
        double best = 0; // iterations per ns
        for (int extra = 0; extra < 8;) {
            long t0 = System.nanoTime();
            spin(n);
            long tookNs = System.nanoTime() - t0;
            best = Math.max(best, (double) n / tookNs);
            if (tookNs < 20_000_000L) {
                n *= 2;
            } else {
                extra++;
            }
        }
        return (long) (best * targetUs * 1000);
    }
}
