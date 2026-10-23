package io.patterncatalyst.lowlat.eliminating;

import java.nio.charset.StandardCharsets;

/**
 * SSCC-18 barcode to 64-bit key. The wire carries the barcode as 18 ASCII digits; the primitive map keys
 * on the packed {@code long}, so the packing happens once, at the edge.
 */
public final class Sscc {

    /** Digits in an SSCC-18. */
    public static final int DIGITS = 18;
    /** Returned by {@link #pack} for anything that is not exactly 18 ASCII digits. A valid key is never negative. */
    public static final long INVALID = -1L;

    private Sscc() {
    }

    /**
     * The 18 digits as a {@code long} (below 10^18), or {@link #INVALID}. A leading zero is a digit:
     * "000000000000000042" packs to 42. One pass over the characters, accumulating as it validates, so packing
     * allocates nothing. {@code Character.isDigit} and {@code Long.parseLong} both accept non-ASCII Unicode
     * digits (Arabic-Indic, for one), which would alias the ASCII barcode, so each character is range-checked.
     */
    public static long pack(CharSequence digits) {
        if (digits.length() != DIGITS) {
            return INVALID;
        }
        long value = 0;
        for (int i = 0; i < DIGITS; i++) {
            char c = digits.charAt(i);
            if (c < '0' || c > '9') {
                return INVALID;
            }
            value = value * 10 + (c - '0');
        }
        return value;
    }

    /** The inverse: {@code value} as 18 zero-padded digits. */
    public static String format(long value) {
        // Not String.format: it allocates a Formatter and boxes per call, ~0.5 KB of garbage per key, and the
        // benchmarks format a million keys while building the working set.
        byte[] digits = new byte[DIGITS];
        for (int i = DIGITS - 1; i >= 0; i--) {
            digits[i] = (byte) ('0' + value % 10);
            value /= 10;
        }
        return new String(digits, StandardCharsets.ISO_8859_1);
    }
}
