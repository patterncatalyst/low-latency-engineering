package io.patterncatalyst.lowlat.co;

/** The line's "handle" step: SSCC serial reference modulo 8 gives the lane. */
final class Handle {

    private Handle() {
    }

    static int laneOf(String sscc) {
        if (sscc.length() != 18) {
            throw new IllegalArgumentException("SSCC-18 must be 18 digits, got '" + sscc + "'");
        }
        long serial = Long.parseLong(sscc, 8, 17, 10); // 9-digit serial reference, no substring
        return (int) (serial % 8);
    }
}
