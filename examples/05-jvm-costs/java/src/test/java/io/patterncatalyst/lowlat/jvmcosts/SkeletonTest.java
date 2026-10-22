package io.patterncatalyst.lowlat.jvmcosts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import org.junit.jupiter.api.Test;

class SkeletonTest {
    @Test
    void wiring() throws Exception {
        assertEquals("jvm-costs", Skeleton.NAME);
        assertNotNull(Class.forName("io.patterncatalyst.lowlat.line.Consumer"));
        assertNotNull(Class.forName("io.patterncatalyst.lowlat.measure.LatencyRecorder"));
        assertNotNull(SkeletonTest.class.getResource("/META-INF/BenchmarkList"), "JMH annotation processor ran");
    }
}
