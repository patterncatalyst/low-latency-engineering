package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.nio.file.Path;
import java.util.Map;

/**
 * One latency recorded three ways: the whole run, the parcels below the window (the first two
 * seconds, which carry JIT warm-up and cold caches) and the steady rest. The same split the
 * line consumers apply to the end-to-end latency, kept here for the stage latencies the decide
 * thread records. Single-writer: the decide thread records, and the report is written after
 * that thread has been joined.
 */
final class SplitRecorder {

    private final long window;
    private final LatencyRecorder all;
    private final LatencyRecorder first;
    private final LatencyRecorder steady;

    SplitRecorder(String example, String variant, long window) {
        this.window = window;
        this.all = LatencyRecorder.singleThreaded(example, variant);
        this.first = LatencyRecorder.singleThreaded(example, variant + "-first-" + window);
        this.steady = LatencyRecorder.singleThreaded(example, variant + "-steady");
    }

    void record(long seq, long latencyNs) {
        all.record(latencyNs);
        (seq < window ? first : steady).record(latencyNs);
    }

    LatencyRecorder all() {
        return all;
    }

    LatencyRecorder steady() {
        return steady;
    }

    /** Writes {@code path}, {@code <stem>-first-N} and {@code <stem>-steady} beside it. */
    void writeReports(Path path, String notes) {
        Map<String, Object> runtime = RuntimeInfo.jvm();
        all.writeReport(path, notes, null, runtime);
        first.writeReport(Handoff.sibling(path, "-first-" + window), notes, null, runtime);
        steady.writeReport(Handoff.sibling(path, "-steady"), notes, null, runtime);
    }
}
