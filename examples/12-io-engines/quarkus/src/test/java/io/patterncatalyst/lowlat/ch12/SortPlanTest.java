package io.patterncatalyst.lowlat.ch12;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class SortPlanTest {

    @Test
    void theLaneIsTheNineDigitSerialModuloEight() {
        assertEquals(5, SortPlan.laneFor("003400001234567890")); // serial 123456789 % 8
        assertEquals(0, SortPlan.laneFor("003400000000000000"));
    }

    @Test
    void aMalformedSsccFallsToLaneZero() {
        assertEquals(0, SortPlan.laneFor("12345"));
        assertEquals(0, SortPlan.laneFor("00340000123456789X"));
    }
}
