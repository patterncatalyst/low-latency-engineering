package io.patterncatalyst.lowlat.ch02;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import tools.jackson.databind.json.JsonMapper;

class ModelTest {

    @Test
    void amdahlTenPercentSerial() {
        assertEquals(1.0, Model.amdahlSpeedup(0.1, 1), 1e-12);
        assertEquals(1.0 / 0.55, Model.amdahlSpeedup(0.1, 2), 1e-12);
        assertEquals(1.0 / 0.325, Model.amdahlSpeedup(0.1, 4), 1e-12);
        assertTrue(Model.amdahlSpeedup(0.1, 1_000_000) < 10.0, "bounded by 1 / s");
    }

    @Test
    void arrivalsFollowTheSchedule() {
        long t0 = 5_000_000_000L;
        assertEquals(0, Model.arrivalsBy(t0 - 1, t0, 1000));
        assertEquals(1, Model.arrivalsBy(t0, t0, 1000));
        assertEquals(1, Model.arrivalsBy(t0 + 999_999, t0, 1000));
        assertEquals(2, Model.arrivalsBy(t0 + 1_000_000, t0, 1000));
        assertEquals(10_001, Model.arrivalsBy(t0 + 10_000_000_000L, t0, 1000));
    }

    @Test
    void warehouseFraming() {
        assertEquals(480.0, Model.littlesL(1000.0, 0.480), 1e-9);
    }

    @Test
    void modelBlockIsAddedAndTheRestKept(@TempDir Path dir) throws Exception {
        Path report = dir.resolve("r.json");
        Files.writeString(report, "{\"schema\":\"lowlat-report/1\",\"count\":3}");
        ModelReport.addModel(report, Map.of("predicted_L", 2.5));
        var root = JsonMapper.builder().build().readTree(report.toFile());
        assertEquals("lowlat-report/1", root.get("schema").asString());
        assertEquals(3, root.get("count").asInt());
        assertEquals(2.5, root.get("model").get("predicted_L").asDouble(), 1e-12);
    }
}
