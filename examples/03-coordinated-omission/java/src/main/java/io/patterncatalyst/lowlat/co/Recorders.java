package io.patterncatalyst.lowlat.co;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;

/** The four recorders of one run. Variant names carry the suffix (for example {@code -control}). */
record Recorders(LatencyRecorder receiptTime, LatencyRecorder intendedTime,
                 LatencyRecorder closedLoopCorrected, LatencyRecorder closedLoopNaive) {

    static final String EXAMPLE = "03-coordinated-omission";

    static Recorders create(String suffix) {
        return new Recorders(
                LatencyRecorder.singleThreaded(EXAMPLE, "receipt-time" + suffix),
                LatencyRecorder.singleThreaded(EXAMPLE, "intended-time" + suffix),
                LatencyRecorder.singleThreaded(EXAMPLE, "closed-loop-corrected" + suffix),
                LatencyRecorder.singleThreaded(EXAMPLE, "closed-loop-naive" + suffix));
    }
}
