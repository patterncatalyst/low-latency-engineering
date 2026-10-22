package io.patterncatalyst.lowlat.line;

/** The r01 "handle" step: map a parcel to one of eight sortation lanes. */
public final class Lanes {

    public static final int LANES = 8;

    private static final int SSCC_LENGTH = 18;
    private static final int SERIAL_START = 8; // extension(1) + company prefix(7)
    private static final int SERIAL_END = 17; // 9-digit serial reference; digit 17 is the check digit

    private Lanes() {
    }

    /**
     * Lane for an SSCC-18: the 9-digit serial reference modulo 8. Decodes the digits in
     * place, with no substring or parse allocation.
     *
     * @throws IllegalArgumentException if {@code sscc} is not 18 ASCII digits
     */
    public static int laneOf(String sscc) {
        if (sscc.length() != SSCC_LENGTH) {
            throw new IllegalArgumentException("SSCC-18 must be 18 digits, got '" + sscc + "'");
        }
        long serial = 0;
        for (int i = 0; i < SSCC_LENGTH; i++) {
            int d = sscc.charAt(i) - '0';
            if (d < 0 || d > 9) { // every position, check digit included, like the C++ sscc_serial
                throw new IllegalArgumentException("SSCC-18 must be digits only, got '" + sscc + "'");
            }
            if (i >= SERIAL_START && i < SERIAL_END) {
                serial = serial * 10 + d;
            }
        }
        return (int) (serial % LANES);
    }
}
