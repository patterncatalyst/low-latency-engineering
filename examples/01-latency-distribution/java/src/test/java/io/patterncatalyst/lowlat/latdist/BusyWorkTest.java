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

    /**
     * A shared CI runner can be slow during calibration and fast afterwards (or the reverse), so
     * one attempt in three must land within a factor of two of the target.
     */
    @Test
    void calibrationLandsWithinAFactorOfTwo() {
        StringBuilder took = new StringBuilder();
        for (int attempt = 0; attempt < 3; attempt++) {
            long n = BusyWork.calibrate(2000);
            long t0 = System.nanoTime();
            BusyWork.spin(n);
            long us = (System.nanoTime() - t0) / 1000;
            if (us > 1000 && us < 4000) {
                return;
            }
            took.append(us).append(" us; ");
        }
        assertTrue(false, "took " + took);
    }
}
