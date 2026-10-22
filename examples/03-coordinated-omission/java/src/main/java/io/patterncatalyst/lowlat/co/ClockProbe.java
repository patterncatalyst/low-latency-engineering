package io.patterncatalyst.lowlat.co;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;

/** Cost of one {@code System.nanoTime()} read: two back-to-back reads, the difference recorded. */
final class ClockProbe {

    private ClockProbe() {
    }

    static void run(long calls, LatencyRecorder nanoTime) {
        for (long i = 0; i < calls; i++) {
            long a = System.nanoTime();
            long b = System.nanoTime();
            nanoTime.record(b - a);
        }
    }
}
