package io.patterncatalyst.lowlat.measure;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.Objects;
import org.HdrHistogram.Histogram;
import org.HdrHistogram.Recorder;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectWriter;
import tools.jackson.databind.PropertyNamingStrategies;
import tools.jackson.databind.SerializationFeature;
import tools.jackson.databind.json.JsonMapper;

/**
 * Records latencies in nanoseconds and writes one {@code lowlat-report/1} JSON
 * report (see {@code examples/common/MEASUREMENT.md}).
 *
 * <p>Two flavours share one API:
 * <ul>
 *   <li>{@link #singleThreaded}: a plain {@link Histogram}. Not thread-safe; use it when one
 *       thread records and the same thread (or a later, happens-after reader) reports.</li>
 *   <li>{@link #concurrent}: backed by {@link Recorder}, so any number of producer threads
 *       record wait-free-ish without a shared lock; reporting folds the interval histogram into
 *       the report histogram. Use it whenever more than one thread records.</li>
 * </ul>
 */
public final class LatencyRecorder {

    /** One hour in ns, three significant digits; identical in all three kits. */
    public static final long HIGHEST_TRACKABLE_NS = 3_600_000_000_000L;
    public static final int SIGNIFICANT_DIGITS = 3;
    public static final String PROFILE_ENV = "LOWLAT_PROFILE";

    private static final ObjectWriter WRITER = JsonMapper.builder()
            .propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
            .enable(SerializationFeature.INDENT_OUTPUT)
            .build()
            .writer();
    private static final JsonMapper READER = JsonMapper.builder().build();

    private final String example;
    private final String variant;
    private final Histogram histogram = newHistogram();
    private final Recorder recorder; // null for the single-threaded flavour
    private long dropped;

    private LatencyRecorder(String example, String variant, Recorder recorder) {
        this.example = Objects.requireNonNull(example, "example");
        this.variant = Objects.requireNonNull(variant, "variant");
        this.recorder = recorder;
    }

    public static LatencyRecorder singleThreaded(String example, String variant) {
        return new LatencyRecorder(example, variant, null);
    }

    public static LatencyRecorder concurrent(String example, String variant) {
        return new LatencyRecorder(example, variant,
                new Recorder(1, HIGHEST_TRACKABLE_NS, SIGNIFICANT_DIGITS));
    }

    public static Histogram newHistogram() {
        return new Histogram(1, HIGHEST_TRACKABLE_NS, SIGNIFICANT_DIGITS);
    }

    /** Record one latency (plain). */
    public void record(long ns) {
        if (recorder != null) {
            recorder.recordValue(ns);
        } else {
            histogram.recordValue(ns);
        }
    }

    /**
     * Record with coordinated-omission correction: back-fills the samples the stalled
     * sender would have taken every {@code expectedIntervalNs}.
     */
    public void recordCorrected(long ns, long expectedIntervalNs) {
        if (recorder != null) {
            recorder.recordValueWithExpectedInterval(ns, expectedIntervalNs);
        } else {
            histogram.recordValueWithExpectedInterval(ns, expectedIntervalNs);
        }
    }

    /** Count parcels that never arrived (sequence gaps). */
    public synchronized void addDropped(long n) {
        dropped += n;
    }

    /**
     * Post-hoc correction of an already-recorded histogram (Ch3 contrasts this with
     * {@link #recordCorrected}). Returns a new histogram; the input is unchanged.
     */
    public static Histogram correctedCopy(Histogram source, long expectedIntervalNs) {
        return source.copyCorrectedForCoordinatedOmission(expectedIntervalNs);
    }

    /** The accumulated histogram, after folding in any pending concurrent samples. */
    public synchronized Histogram histogram() {
        if (recorder != null) {
            histogram.add(recorder.getIntervalHistogram());
        }
        return histogram;
    }

    public Report report() {
        return report(null);
    }

    /** As {@link #report()}; {@code notes} is written only when non-null and non-empty. */
    public Report report(String notes) {
        Histogram h = histogram();
        return new Report(Report.SCHEMA, example, "java", variant, "ns",
                h.getTotalCount(), dropped(),
                new Percentiles(h.getValueAtPercentile(50), h.getValueAtPercentile(90),
                        h.getValueAtPercentile(99), h.getValueAtPercentile(99.9), h.getMaxValue()),
                encode(h), BuildInfo.current(), loadProfile(),
                notes == null || notes.isEmpty() ? null : notes);
    }

    /** Write the report as JSON and return it. Fails if {@code LOWLAT_PROFILE} is unset. */
    public Report writeReport(Path path) {
        return writeReport(path, null);
    }

    /** As {@link #writeReport(Path)}, with optional free-text {@code notes} (omitted when empty). */
    public Report writeReport(Path path, String notes) {
        Report report = report(notes);
        try {
            Path parent = path.toAbsolutePath().getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }
            Files.writeString(path, WRITER.writeValueAsString(report) + System.lineSeparator());
        } catch (IOException e) {
            throw new UncheckedIOException("cannot write report " + path, e);
        }
        return report;
    }

    /** One aligned line, microseconds with one decimal. Never a mean. */
    public void printSummary() {
        Report r = report();
        Percentiles p = r.percentiles();
        System.out.printf("%-26s %-6s %-18s %10d %8d %10.1f %10.1f %10.1f %10.1f %10.1f%n",
                r.example(), r.language(), r.variant(), r.count(), r.dropped(),
                us(p.p50()), us(p.p90()), us(p.p99()), us(p.p999()), us(p.max()));
    }

    /** Compressed V2 encoding, base64: the {@code HISTFAAA...} form. */
    public static String encode(Histogram h) {
        ByteBuffer buffer = ByteBuffer.allocate(h.getNeededByteBufferCapacity());
        int length = h.encodeIntoCompressedByteBuffer(buffer);
        byte[] bytes = new byte[length];
        buffer.rewind().get(bytes);
        return Base64.getEncoder().encodeToString(bytes);
    }

    public static Histogram decode(String base64) {
        ByteBuffer buffer = ByteBuffer.wrap(Base64.getDecoder().decode(base64));
        try {
            return Histogram.decodeFromCompressedByteBuffer(buffer, 0);
        } catch (java.util.zip.DataFormatException e) {
            throw new IllegalArgumentException("not a compressed HdrHistogram", e);
        }
    }

    private synchronized long dropped() {
        return dropped;
    }

    private static double us(long ns) {
        return ns / 1000.0;
    }

    private static JsonNode loadProfile() {
        String env = System.getenv(PROFILE_ENV);
        if (env == null || env.isBlank()) {
            throw new IllegalStateException(PROFILE_ENV + " is not set: a number without a machine "
                    + "profile is not publishable. Run scripts/profile.sh --out FILE and export "
                    + PROFILE_ENV + "=FILE.");
        }
        Path file = Path.of(env);
        if (!Files.isRegularFile(file)) {
            throw new IllegalStateException(PROFILE_ENV + " names a missing file: " + file);
        }
        return READER.readTree(file.toFile());
    }
}
