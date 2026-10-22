package io.patterncatalyst.lowlat.co;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.util.List;
import org.junit.jupiter.api.Test;

class ExperimentTest {

    @Test
    void defaults() {
        Options o = Options.parse(List.of());
        assertEquals(200, o.stallMs());
        assertEquals(5000, o.stallSeq());
        assertEquals(10_000, o.expect());
    }

    @Test
    void controlRun() {
        Options o = Options.parse(List.of("--stall-ms", "0", "--suffix", "-control"));
        assertEquals(0, o.stallMs());
        assertEquals("-control", o.suffix());
    }

    @Test
    void rejectsBadArguments() {
        assertThrows(IllegalArgumentException.class, () -> Options.parse(List.of("--nope", "1")));
        assertThrows(IllegalArgumentException.class, () -> Options.parse(List.of("--stall-ms")));
    }

    @Test
    void bindIsCheckedLikeTheOtherConsumers() {
        Options o = Options.parse(List.of("--bind", "0.0.0.0:47300"));
        assertEquals("0.0.0.0", o.bindHost());
        assertEquals(47300, o.bindPort());
        assertThrows(IllegalArgumentException.class, () -> Options.parse(List.of("--bind", "127.0.0.1:70000")));
        assertThrows(IllegalArgumentException.class, () -> Options.parse(List.of("--bind", ":47300")));
    }

    /** The correction is the point: the same closed-loop stall, recorded two ways. */
    @Test
    void correctionBackfillsTheStall() {
        Options o = Options.parse(List.of("--stall-ms", "50", "--stall-seq", "100"));
        Recorders rec = Recorders.create("");
        Experiment.closedLoop(o, 300, rec);
        assertEquals(300, rec.closedLoopNaive().histogram().getTotalCount());
        assertTrue(rec.closedLoopCorrected().histogram().getTotalCount() > 300 + 40);
    }

    @Test
    void clockProbeRecordsEveryCall() {
        LatencyRecorder r = LatencyRecorder.singleThreaded(Recorders.EXAMPLE, "clock-read");
        ClockProbe.run(1000, r);
        assertEquals(1000, r.histogram().getTotalCount());
    }
}
