package io.patterncatalyst.lowlat.jvmcosts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.jvmcosts.JitWindows.Windows;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import jdk.jfr.Recording;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

class JitWindowsTest {

    private static final Instant T0 = Instant.parse("2026-10-22T12:00:00Z");
    private static final Windows WINDOWS = new Windows(T0, T0.plusSeconds(2), T0.plusSeconds(20), 2000);

    @Test
    void eventsFallInTheWindowTheirStartTimeIsIn() {
        assertEquals("startup", WINDOWS.keyOf(T0.minusMillis(1)));
        assertEquals("first-2000", WINDOWS.keyOf(T0));
        assertEquals("first-2000", WINDOWS.keyOf(T0.plusMillis(1999)));
        assertEquals("steady", WINDOWS.keyOf(T0.plusSeconds(2)));
        assertEquals("steady", WINDOWS.keyOf(T0.plusSeconds(20)));
        assertNull(WINDOWS.keyOf(T0.plusSeconds(21)), "after the run ended");
    }

    @Test
    void countsCompilationsFromARecording(@TempDir Path dir) throws IOException {
        Path jfr = dir.resolve("jit.jfr");
        try (Recording recording = new Recording()) {
            recording.enable(JitWindows.COMPILATION).withThreshold(Duration.ZERO);
            recording.enable(JitWindows.DEOPTIMIZATION);
            recording.start();
            // Enough calls for C1 to compile decide() and the code around it.
            long sink = 0;
            var events = SyntheticParcels.batch(1024, 3);
            for (int round = 0; round < 200; round++) {
                for (var event : events) {
                    sink += Tracker.decide(event).lane();
                }
            }
            assertTrue(sink > 0);
            recording.stop();
            recording.dump(jfr);
        }
        Windows everything = new Windows(Instant.EPOCH, Instant.now().plusSeconds(60), Instant.now().plusSeconds(120), 2000);
        Map<String, Map<String, Long>> counts = JitWindows.count(jfr, everything);
        assertEquals(List.of("startup", "first-2000", "steady"), List.copyOf(counts.keySet()));
        assertTrue(counts.get("first-2000").get("compilations") > 0, "the hot loop was compiled");
        assertEquals(0, counts.get("startup").get("compilations"));
    }

    @Test
    void addsRuntimeJitAndKeepsTheRestOfTheReport(@TempDir Path dir) throws IOException {
        Path report = dir.resolve("report.json");
        Files.writeString(report, "{\"count\": 5, \"runtime\": {\"gc\": {\"name\": \"G1\"}}}");
        JitWindows.addTo(report, Map.of("steady", Map.of("compilations", 3L, "c2_compilations", 1L, "deoptimizations", 0L)));
        JsonNode root = JsonMapper.builder().build().readTree(report);
        assertEquals(5, root.get("count").asInt());
        assertEquals("G1", root.get("runtime").get("gc").get("name").asString());
        assertEquals(3, root.get("runtime").get("jit").get("steady").get("compilations").asInt());
    }

    @Test
    void createsTheRuntimeBlockWhenThereIsNone(@TempDir Path dir) throws IOException {
        Path report = dir.resolve("report.json");
        Files.writeString(report, "{\"count\": 5}");
        JitWindows.addTo(report, Map.of("steady", Map.of("compilations", 3L)));
        assertEquals(3, JsonMapper.builder().build().readTree(report).get("runtime").get("jit").get("steady")
                .get("compilations").asInt());
    }
}
