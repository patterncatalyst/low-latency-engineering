package io.patterncatalyst.lowlat.latdist;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class BusyWorkTest {

    @Test
    void spinIsDeterministicAndNotConstant() {
        assertEquals(BusyWork.spin(1000), BusyWork.spin(1000));
        assertNotEquals(BusyWork.spin(1000), BusyWork.spin(1001));
    }

    @Test
    void calibrationLandsWithinAFactorOfTwo() {
        long n = BusyWork.calibrate(2000);
        long t0 = System.nanoTime();
        BusyWork.spin(n);
        long us = (System.nanoTime() - t0) / 1000;
        assertTrue(us > 1000 && us < 4000, "took " + us + " us");
    }
}
