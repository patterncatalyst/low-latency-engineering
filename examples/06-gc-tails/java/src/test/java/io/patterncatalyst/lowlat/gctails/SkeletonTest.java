package io.patterncatalyst.lowlat.gctails;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import org.junit.jupiter.api.Test;

class SkeletonTest {
    @Test
    void wiring() throws Exception {
        assertEquals("gc-tails", Skeleton.NAME);
        assertNotNull(Class.forName("io.patterncatalyst.lowlat.line.Consumer"));
        assertNotNull(Class.forName("io.patterncatalyst.lowlat.measure.LatencyRecorder"));
    }
}
