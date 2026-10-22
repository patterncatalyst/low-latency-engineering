package io.patterncatalyst.lowlat.measure;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.stream.IntStream;
import org.HdrHistogram.Histogram;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

class LatencyRecorderTest {

    private static final long MS = 1_000_000L;
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static Path fixtures;

    /** The measure-fixtures directory, found through the profile surefire points LOWLAT_PROFILE at. */
    @BeforeAll
    static void locateFixtures() {
        String profile = System.getenv(LatencyRecorder.PROFILE_ENV);
        assumeTrue(profile != null && !profile.isBlank(), LatencyRecorder.PROFILE_ENV + " not set (run through Maven)");
        fixtures = Path.of(profile).toAbsolutePath().normalize().getParent();
    }

    @Test
    void correctionBackfillsAndRaisesP99() {
        LatencyRecorder plain = LatencyRecorder.singleThreaded("t", "plain");
        LatencyRecorder inline = LatencyRecorder.singleThreaded("t", "inline");
        for (int i = 0; i < 1000; i++) {
            plain.record(MS);
            inline.record(MS);
        }
        plain.record(1_000 * MS);
        inline.recordCorrected(1_000 * MS, MS);

        Histogram plainH = plain.histogram();
        Histogram inlineH = inline.histogram();
        Histogram posthoc = LatencyRecorder.correctedCopy(plainH, MS);

        assertEquals(1001, plainH.getTotalCount());
        assertEquals(2000, inlineH.getTotalCount());
        assertEquals(2000, posthoc.getTotalCount());
        assertTrue(inlineH.getValueAtPercentile(99) > MS, "corrected p99 must exceed 1 ms");
        assertTrue(plainH.valuesAreEquivalent(plainH.getValueAtPercentile(99), MS),
                "plain p99 is 1 ms within the equivalent range");
        assertEquals(inlineH.getValueAtPercentile(99), posthoc.getValueAtPercentile(99));
        for (double pct : new double[] {50, 90, 99, 99.9}) {
            assertTrue(withinOneBucket(inlineH, inlineH.getValueAtPercentile(pct),
                    posthoc.getValueAtPercentile(pct)), "p" + pct);
        }
        assertTrue(withinOneBucket(inlineH, inlineH.getMaxValue(), posthoc.getMaxValue()));
    }

    /**
     * Inline and post-hoc correction back-fill with the same rule but round per call, so a
     * percentile may land in the adjacent bucket; "agree" means equivalent or neighbouring.
     */
    private static boolean withinOneBucket(Histogram h, long a, long b) {
        long lo = Math.min(a, b);
        long hi = Math.max(a, b);
        return h.valuesAreEquivalent(lo, hi) || h.valuesAreEquivalent(h.nextNonEquivalentValue(lo), hi);
    }

    @Test
    void goldenReportRoundTripsAndValidatesShape() throws IOException {
        LatencyRecorder rec = LatencyRecorder.singleThreaded("measure-fixtures", "golden");
        for (int i = 1; i <= 10_000; i++) {
            rec.record(i * 1000L);
        }
        Path out = fixtures.resolve("java-golden.json");
        Report report = rec.writeReport(out);

        assertEquals(10_000, report.count());
        Histogram decoded = LatencyRecorder.decode(report.hdrHistogram());
        assertEquals(rec.histogram(), decoded);

        JsonNode tree = JSON.readTree(out);
        for (String field : List.of("schema", "example", "language", "variant", "unit", "count",
                "dropped", "percentiles", "hdr_histogram", "build", "profile")) {
            assertTrue(tree.has(field), "missing " + field);
        }
        assertEquals("lowlat-report/1", tree.get("schema").asString());
        assertEquals("java", tree.get("language").asString());
        assertEquals("lowlat-profile/1", tree.get("profile").get("schema").asString());
        assertTrue(tree.get("build").has("gil_enabled"));
        assertTrue(tree.get("build").get("gil_enabled").isNull());
        assertEquals(tree.get("percentiles").get("max").asLong(), decoded.getMaxValue());
        assertTrue(tree.get("percentiles").has("p99_9"));
    }

    @Test
    void noMeanAnywhereInReport(@TempDir Path dir) throws IOException {
        LatencyRecorder rec = LatencyRecorder.singleThreaded("t", "v");
        rec.record(5_000);
        Path out = dir.resolve("report.json");
        rec.writeReport(out);
        // the embedded profile is excluded: scan only the report-owned keys
        JsonNode tree = JSON.readTree(out);
        for (String key : tree.propertyNames()) {
            assertFalse(key.toLowerCase().contains("mean"), key);
        }
        for (String key : tree.get("percentiles").propertyNames()) {
            assertFalse(key.toLowerCase().contains("mean"), key);
        }
        assertEquals(5, tree.get("percentiles").size());
    }

    /** Needs java-golden.json from {@link #goldenReportRoundTripsAndValidatesShape}; skipped if absent. */
    @ParameterizedTest
    @ValueSource(strings = {"cpp-golden.json", "python-golden.json"})
    void crossDecodeOtherLanguages(String name) throws IOException {
        Path java = fixtures.resolve("java-golden.json");
        assumeTrue(Files.exists(java), "java-golden.json not yet written");
        Path other = fixtures.resolve(name);
        assumeTrue(Files.exists(other), name + " not present; nothing to cross-decode");
        Histogram ref = LatencyRecorder.decode(JSON.readTree(java).get("hdr_histogram").asString());
        Histogram h = LatencyRecorder.decode(JSON.readTree(other).get("hdr_histogram").asString());
        assertEquals(ref.getTotalCount(), h.getTotalCount(), name);
        for (double p : new double[] {50, 90, 99, 99.9}) {
            assertTrue(ref.valuesAreEquivalent(ref.getValueAtPercentile(p), h.getValueAtPercentile(p)),
                    name + " p" + p);
        }
        assertTrue(ref.valuesAreEquivalent(ref.getMaxValue(), h.getMaxValue()), name + " max");
    }

    @Test
    void concurrentRecorderKeepsEveryCount() throws InterruptedException {
        int threads = 4;
        int perThread = 100_000;
        LatencyRecorder rec = LatencyRecorder.concurrent("t", "concurrent");
        CountDownLatch start = new CountDownLatch(1);
        List<Thread> workers = IntStream.range(0, threads)
                .mapToObj(t -> Thread.ofPlatform().unstarted(() -> {
                    try {
                        start.await();
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                    for (int i = 1; i <= perThread; i++) {
                        rec.record(i * 10L);
                    }
                }))
                .toList();
        workers.forEach(Thread::start);
        start.countDown();
        for (Thread w : workers) {
            w.join();
        }
        assertEquals((long) threads * perThread, rec.histogram().getTotalCount());
        assertNotNull(rec.report().hdrHistogram());
        // a second fold must not double count
        assertEquals((long) threads * perThread, rec.report().count());
    }

    @Test
    void notesAppearOnlyWhenGiven(@TempDir Path dir) throws IOException {
        LatencyRecorder rec = LatencyRecorder.singleThreaded("t", "notes");
        rec.record(MS);
        Path plain = dir.resolve("plain.json");
        Path noted = dir.resolve("noted.json");
        Path empty = dir.resolve("empty.json");
        rec.writeReport(plain);
        rec.writeReport(noted, "reordered=0; rcvbuf_requested=1; rcvbuf_granted=2");
        rec.writeReport(empty, "");
        assertFalse(JSON.readTree(plain).has("notes"));
        assertFalse(JSON.readTree(empty).has("notes"));
        assertEquals("reordered=0; rcvbuf_requested=1; rcvbuf_granted=2",
                JSON.readTree(noted).get("notes").asString());
    }

    @Test
    void modelBlockIsCarriedAndOmittedWhenAbsent(@TempDir Path dir) throws IOException {
        LatencyRecorder rec = LatencyRecorder.singleThreaded("t", "model");
        rec.record(MS);
        Path plain = dir.resolve("plain.json");
        Path modelled = dir.resolve("modelled.json");
        rec.writeReport(plain);
        rec.writeReport(modelled, "n", Map.of("predicted_L", 2.5,
                "warehouse", Map.of("belt_mps", 2)));
        assertFalse(JSON.readTree(plain).has("model"));
        JsonNode tree = JSON.readTree(modelled);
        assertEquals(2.5, tree.get("model").get("predicted_L").asDouble(), 1e-12);
        assertEquals(2, tree.get("model").get("warehouse").get("belt_mps").asInt());
        assertEquals("n", tree.get("notes").asString());
        // the schema allows exactly the documented keys, model among them
        for (String field : List.of("schema", "example", "language", "variant", "unit", "count",
                "dropped", "percentiles", "hdr_histogram", "build", "profile")) {
            assertTrue(tree.has(field), field);
        }
    }
}
