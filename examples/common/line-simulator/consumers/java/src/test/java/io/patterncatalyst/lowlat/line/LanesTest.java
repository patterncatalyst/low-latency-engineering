package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

class LanesTest {

    @Test
    void laneIsNineDigitSerialModuloEight() {
        // extension 0, company 0614141, serial 000000013, check digit irrelevant
        assertEquals(5, Lanes.laneOf("006141410000000130"));
        assertEquals(0, Lanes.laneOf("006141410000000000"));
        assertEquals(7, Lanes.laneOf("006141419999999990")); // 999999999 % 8 = 7
    }

    @Test
    void everyLaneIsInRange() {
        for (int serial = 0; serial < 1000; serial++) {
            int lane = Lanes.laneOf("00614141%09d0".formatted(serial));
            assertEquals(serial % 8, lane);
        }
    }

    @Test
    void rejectsMalformedBarcodes() {
        assertThrows(IllegalArgumentException.class, () -> Lanes.laneOf("123"));
        assertThrows(IllegalArgumentException.class, () -> Lanes.laneOf("00614141000000x000"));
    }
}
