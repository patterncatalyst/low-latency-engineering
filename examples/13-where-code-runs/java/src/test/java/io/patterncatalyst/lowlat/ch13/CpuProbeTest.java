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
    void mountedVirtualThreadsNeverExceedTheProcessorCountAndAreAtLeastOne() {
        int processors = CpuProbe.availableProcessors();
        long mounted = CpuProbe.mountedMax(processors);
        assertTrue(mounted >= 1 && mounted <= processors, "mounted " + mounted + " of " + processors);
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
        assertEquals(CpuProbe.availableProcessors(), java.get("virtual_thread_parallelism"));
        assertTrue((Integer) java.get("virtual_thread_pool_size_after_spin") >= 1);
    }

    @Test
    void writesJsonToTheFileNamedByOut(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("probe.json");
        CpuProbe.main(new String[] {"--out", file.toString()});
        String text = Files.readString(file);
        assertTrue(text.contains("\"available_processors\""), text);
        assertTrue(text.contains("\"virtual_thread_mounted_max\""), text);
    }
}
