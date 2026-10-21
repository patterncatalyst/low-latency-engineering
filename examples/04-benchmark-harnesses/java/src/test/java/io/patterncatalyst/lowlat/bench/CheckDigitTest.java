package io.patterncatalyst.lowlat.bench;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

/** Parity with the C++ reference (GS1 known-good values, see cpp/check_digit_test.cpp). */
class CheckDigitTest {

    @Test
    void knownGoodCheckDigits() {
        // GS1 General Specifications example (00) 1 0614141 123456789 7.
        assertEquals(7, CheckDigit.of("10614141123456789"));
        assertEquals(4, CheckDigit.of("00614141000000007"));
        assertEquals(0, CheckDigit.of("00000000000000000"));
    }

    @Test
    void benchmarkPrefixSetIsStable() {
        String[] p = CheckDigit.prefixes(1024);
        assertEquals("00614141000000013", p[0]);
        assertEquals("10614141000007932", p[1]);
        assertEquals(17, p[1023].length());
    }

    @Test
    void rejectsWrongLength() {
        assertThrows(IllegalArgumentException.class, () -> CheckDigit.of("123"));
    }
}
