package io.patterncatalyst.lowlat.offheap;

/** The SSCC-18 field the decide step needs, read in place without allocating. */
final class Barcode {

    private static final int SSCC_LENGTH = 18;
    private static final int SERIAL_START = 8; // extension (1) + company prefix (7)
    private static final int SERIAL_END = 17; // the 9-digit serial reference; position 17 is the check digit

    private Barcode() {
    }

    /**
     * The 9-digit serial reference of {@code sscc}: the same digits {@code Lanes.laneOf} takes
     * modulo 8, kept as a number so the hand-off carries 8 bytes instead of an 18-character string.
     *
     * @throws IllegalArgumentException if {@code sscc} is not 18 ASCII digits
     */
    static long serial(String sscc) {
        if (sscc.length() != SSCC_LENGTH) {
            throw new IllegalArgumentException("SSCC-18 must be 18 digits, got '" + sscc + "'");
        }
        long serial = 0;
        for (int i = 0; i < SSCC_LENGTH; i++) {
            int d = sscc.charAt(i) - '0';
            if (d < 0 || d > 9) {
                throw new IllegalArgumentException("SSCC-18 must be digits only, got '" + sscc + "'");
            }
            if (i >= SERIAL_START && i < SERIAL_END) {
                serial = serial * 10 + d;
            }
        }
        return serial;
    }
}
