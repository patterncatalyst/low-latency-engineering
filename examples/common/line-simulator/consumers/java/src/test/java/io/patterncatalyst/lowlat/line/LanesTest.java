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

    @Test
    void rejectsAnyNonAsciiDigitOrWrongLength() {
        // 18 chars, bad only in the last position: outside the serial but still not an SSCC (as in C++)
        assertThrows(IllegalArgumentException.class, () -> Lanes.laneOf("00614141000000013x"));
        assertThrows(IllegalArgumentException.class, () -> Lanes.laneOf("x06141410000000130"));
        assertThrows(IllegalArgumentException.class, () -> Lanes.laneOf("00614141000000013")); // 17
        assertThrows(IllegalArgumentException.class, () -> Lanes.laneOf("0061414100000001300")); // 19
        // Arabic-Indic digits: Character.isDigit would accept them
        assertThrows(IllegalArgumentException.class,
                () -> Lanes.laneOf("\u0660\u0660\u0666\u0661\u0664\u0661\u0664\u0661\u0660\u0660\u0660\u0660\u0660\u0660\u0660\u0661\u0663\u0660"));
    }

    @Test
    void matchesTheCppFixtures() { // the barcodes the C++ Lane.SerialModuloEight test uses
        assertEquals(5, Lanes.laneOf("006141410000000134"));
        assertEquals(0, Lanes.laneOf("006141410000000008"));
        assertEquals(7, Lanes.laneOf("006141419999999997"));
        assertEquals(7, Lanes.laneOf("906141410000000070"));
    }
}
