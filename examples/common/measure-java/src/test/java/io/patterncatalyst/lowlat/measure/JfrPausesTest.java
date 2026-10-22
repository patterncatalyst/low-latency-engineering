package io.patterncatalyst.lowlat.measure;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import jdk.jfr.Recording;
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordingFile;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

class JfrPausesTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    @BeforeAll
    static void profileSet() {
        String profile = System.getenv(LatencyRecorder.PROFILE_ENV);
        assumeTrue(profile != null && !profile.isBlank(), LatencyRecorder.PROFILE_ENV + " not set (run through Maven)");
    }

    @Test
    void reportCountEqualsPauseEventsInTheRecording(@TempDir Path dir) throws IOException {
        Path jfr = dir.resolve("run.jfr");
        try (Recording r = new Recording()) {
            r.enable(JfrPauses.PAUSE);
            r.enable(JfrPauses.CONFIG);
            r.setDestination(jfr);
            r.start();
            List<byte[]> keep = new ArrayList<>();
            for (int i = 0; i < 5; i++) {
                for (int j = 0; j < 2_000; j++) {
                    keep.add(new byte[1024]);
                }
                keep.clear();
                System.gc();
            }
            r.stop();
        }

        long expected = 0;
        try (RecordingFile f = new RecordingFile(jfr)) {
            while (f.hasMoreEvents()) {
                RecordedEvent e = f.readEvent();
                if (e.getEventType().getName().equals(JfrPauses.PAUSE)) {
                    expected++;
                }
            }
        }
        assertTrue(expected >= 5, "System.gc() must produce pause events, saw " + expected);

        Path out = dir.resolve("gc.json");
        Report report = JfrPauses.write(jfr, "jfr-test", "ex", out, null);
        assertEquals(expected, report.count());
        assertEquals("ex-gc-pause", report.variant());

        JsonNode json = JSON.readTree(Files.readString(out));
        assertEquals(expected, json.get("count").asLong());
        assertEquals("lowlat-report/1", json.get("schema").asString());
        assertTrue(json.get("runtime").has("alloc_stalls"));
        assertEquals(0, json.get("runtime").get("alloc_stalls").get("count").asLong());
        assertTrue(json.get("runtime").get("gc").get("collectors").size() >= 1);
        assertTrue(json.get("percentiles").get("max").asLong() >= Duration.ofNanos(1).toNanos());
    }
}
