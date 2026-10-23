package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/**
 * Latency of one run split at parcel {@code window}: parcels with {@code seq < window} go to
 * {@link #first()}, the rest to {@link #steady()}. The first window carries the warm-up (JIT,
 * class loading, cold caches), the steady one what follows; the two counts add up to the full
 * report's count.
 *
 * <p>Recorded in addition to the full recorder, not instead of it, so the full
 * {@code <variant>} report keeps its meaning. Only a run given a window pays the second
 * record. Like {@link Completion}, which feeds it, it is single-writer.
 */
public final class WindowedRecorders {

    private final long window;
    private final LatencyRecorder first;
    private final LatencyRecorder steady;

    public WindowedRecorders(String example, String variant, long window) {
        if (window < 1) {
            throw new IllegalArgumentException("window must be at least 1, got " + window);
        }
        this.window = window;
        this.first = LatencyRecorder.singleThreaded(example, variant + "-first-" + window);
        this.steady = LatencyRecorder.singleThreaded(example, variant + "-steady");
    }

    public long window() {
        return window;
    }

    public LatencyRecorder first() {
        return first;
    }

    public LatencyRecorder steady() {
        return steady;
    }

    void record(long seq, long latencyNs) {
        (seq < window ? first : steady).record(latencyNs);
    }

    /**
     * Writes {@code <stem>-first-N<ext>} and {@code <stem>-steady<ext>} beside {@code report} and
     * returns the two paths. Call it after the thread that completes parcels has finished.
     */
    public List<Path> writeReports(Path report, String notes, Map<String, Object> runtime) {
        String windowNote = "window=" + window + "; first window is seq < " + window;
        String text = notes == null || notes.isEmpty() ? windowNote : notes + "; " + windowNote;
        List<Path> written = List.of(sibling(report, "-first-" + window), sibling(report, "-steady"));
        first.writeReport(written.get(0), text, null, runtime);
        steady.writeReport(written.get(1), text, null, runtime);
        return written;
    }

    /** {@code dir/run.json} with suffix {@code -steady} is {@code dir/run-steady.json}. */
    public static Path sibling(Path report, String suffix) {
        String name = report.getFileName().toString();
        int dot = name.lastIndexOf('.');
        String renamed = dot <= 0 ? name + suffix : name.substring(0, dot) + suffix + name.substring(dot);
        Path parent = report.getParent();
        return parent == null ? Path.of(renamed) : parent.resolve(renamed);
    }
}
