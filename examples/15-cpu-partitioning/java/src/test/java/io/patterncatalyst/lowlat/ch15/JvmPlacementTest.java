package io.patterncatalyst.lowlat.ch15;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** Unprivileged: the report shape, the option checks and the status parse. */
class JvmPlacementTest {

    @Test
    void statusCounterReadsTheNamedLine() {
        String status = "Name:\tjava\nvoluntary_ctxt_switches:\t12\nnonvoluntary_ctxt_switches:\t3\n";
        assertEquals(12, JvmPlacement.statusCounter(status, "voluntary_ctxt_switches"));
        assertEquals(3, JvmPlacement.statusCounter(status, "nonvoluntary_ctxt_switches"));
        assertEquals(-1, JvmPlacement.statusCounter(status, "missing"));
    }

    @Test
    void optionsAreChecked() {
        assertThrows(IllegalArgumentException.class, () -> JvmPlacement.Options.parse(new String[] {"--mode", "elsewhere"}));
        assertThrows(IllegalArgumentException.class, () -> JvmPlacement.Options.parse(new String[] {"--mode", "hot-thread"}));
        assertThrows(IllegalArgumentException.class, () -> JvmPlacement.Options.parse(new String[] {"--mode", "taskset", "--seconds"}));
        var ok = JvmPlacement.Options.parse(new String[] {"--mode", "taskset", "--seconds", "1", "--isolated", "2-3", "--out", "x.json"});
        assertEquals(Path.of("x.json"), ok.out());
        assertTrue(ok.isolated().get(2) && ok.isolated().get(3));
    }

    @Test
    @SuppressWarnings("unchecked")
    void aTasksetRunReportsTwoHotThreadsAndEveryJvmThread() throws Exception {
        var options = JvmPlacement.Options.parse(new String[] {"--mode", "taskset", "--seconds", "1", "--isolated", "999"});
        Map<String, Object> report = JvmPlacement.run(options);
        assertEquals("lowlat-placement-java/1", report.get("schema"));
        assertEquals(2, ((List<Object>) report.get("hot_threads")).size());
        assertTrue((int) report.get("threads_total") >= 5, report.toString());
        assertEquals(0, report.get("threads_on_isolated"));
        for (Object row : (List<Object>) report.get("hot_threads")) {
            assertTrue((long) ((Map<String, Object>) row).get("involuntary_switches") >= 0);
        }
    }
}
