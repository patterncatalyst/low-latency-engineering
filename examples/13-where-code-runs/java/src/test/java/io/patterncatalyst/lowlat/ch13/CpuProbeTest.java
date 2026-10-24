package io.patterncatalyst.lowlat.ch13;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class CpuProbeTest {

    @Test
    void reportsAtLeastOneProcessor() {
        assertTrue(CpuProbe.availableProcessors() >= 1);
    }

    @Test
    void carriersNeverExceedTheProcessorCountAndAreAtLeastOne() {
        int processors = CpuProbe.availableProcessors();
        int carriers = CpuProbe.observedCarriers(processors);
        assertTrue(carriers >= 1 && carriers <= processors, "carriers " + carriers + " of " + processors);
    }

    @Test
    void theGcThreadFlagsAreNumbersOrAbsent() {
        assertTrue(CpuProbe.vmOption("ParallelGCThreads") >= -1);
        assertEquals(-1, CpuProbe.vmOption("NoSuchFlagInThisVm"));
    }

    @SuppressWarnings("unchecked")
    @Test
    void probeCarriesTheExactCounts() {
        Map<String, Object> out = CpuProbe.probe();
        assertEquals("lowlat-place-probe/1", out.get("schema"));
        Map<String, Object> java = (Map<String, Object>) out.get("java");
        assertEquals(CpuProbe.availableProcessors(), java.get("available_processors"));
        assertEquals(CpuProbe.availableProcessors(), java.get("virtual_thread_parallelism_expected"));
    }

    @Test
    void writesJsonToTheFileNamedByOut(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("probe.json");
        CpuProbe.main(new String[] {"--out", file.toString()});
        String text = Files.readString(file);
        assertTrue(text.contains("\"available_processors\""), text);
        assertTrue(text.contains("\"virtual_thread_carriers_observed\""), text);
    }
}
