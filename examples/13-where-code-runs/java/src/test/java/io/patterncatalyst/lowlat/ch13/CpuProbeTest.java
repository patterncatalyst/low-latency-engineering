package io.patterncatalyst.lowlat.ch13;

import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class CpuProbeTest {

    @Test
    void reportsAtLeastOneProcessor() {
        assertTrue(CpuProbe.availableProcessors() >= 1);
    }
}
