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
import java.util.concurrent.CountDownLatch;
import java.util.stream.IntStream;
import org.HdrHistogram.Histogram;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

class LatencyRecorderTest {

    private static final long MS = 1_000_000L;
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final Path FIXTURES =
            Path.of(System.getenv(LatencyRecorder.PROFILE_ENV)).toAbsolutePath().normalize().getParent();

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
        Path out = FIXTURES.resolve("java-golden.json");
        Report report = rec.writeReport(out);

        assertEquals(10_000, report.count());
        Histogram decoded = LatencyRecorder.decode(report.hdrHistogram());
        assertEquals(rec.histogram(), decoded);

        JsonNode tree = JSON.readTree(out.toFile());
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
    void noMeanAnywhereInReport() throws IOException {
        LatencyRecorder rec = LatencyRecorder.singleThreaded("t", "v");
        rec.record(5_000);
        Path out = Files.createTempFile("report", ".json");
        try {
            rec.writeReport(out);
            String text = Files.readString(out);
            // the embedded profile is excluded: scan only the report-owned keys
            JsonNode tree = JSON.readTree(text);
            for (String key : tree.propertyNames()) {
                assertFalse(key.toLowerCase().contains("mean"), key);
            }
            for (String key : tree.get("percentiles").propertyNames()) {
                assertFalse(key.toLowerCase().contains("mean"), key);
            }
            assertEquals(5, tree.get("percentiles").size());
        } finally {
            Files.deleteIfExists(out);
        }
    }

    @Test
    void crossDecodeOtherLanguages() throws IOException {
        Path java = FIXTURES.resolve("java-golden.json");
        assumeTrue(Files.exists(java), "java-golden.json not yet written");
        Histogram ref = LatencyRecorder.decode(JSON.readTree(java.toFile()).get("hdr_histogram").asString());
        boolean any = false;
        for (String name : List.of("cpp-golden.json", "python-golden.json")) {
            Path other = FIXTURES.resolve(name);
            if (!Files.exists(other)) {
                System.out.println("skipping " + name + ": not present");
                continue;
            }
            any = true;
            Histogram h = LatencyRecorder.decode(JSON.readTree(other.toFile()).get("hdr_histogram").asString());
            assertEquals(ref.getTotalCount(), h.getTotalCount(), name);
            for (double p : new double[] {50, 90, 99, 99.9}) {
                assertTrue(ref.valuesAreEquivalent(ref.getValueAtPercentile(p), h.getValueAtPercentile(p)),
                        name + " p" + p);
            }
            assertTrue(ref.valuesAreEquivalent(ref.getMaxValue(), h.getMaxValue()), name + " max");
        }
        assumeTrue(any, "no cpp-golden.json or python-golden.json present; nothing to cross-decode");
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
}
