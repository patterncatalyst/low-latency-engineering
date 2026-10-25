package io.patterncatalyst.lowlat.ch12;

/** The sort-plan lookup the warehouse management system (WMS) answers: the lane for an SSCC-18. */
final class SortPlan {

    /** The downstream wait, in milliseconds: the WMS round trip each lookup stands in for. */
    static final long WAIT_MS = 2;

    private static final int LANES = 8;
    private static final int SERIAL_START = 8;
    private static final int SERIAL_END = 17;

    private SortPlan() {
    }

    /** The 9-digit serial of an SSCC-18 modulo 8; anything else is a bad request upstream, so it falls to lane 0. */
    static int laneFor(String sscc) {
        if (sscc.length() != 18) {
            return 0;
        }
        long serial = 0;
        for (int i = 0; i < 18; i++) {
            int digit = sscc.charAt(i) - '0';
            if (digit < 0 || digit > 9) {
                return 0;
            }
            if (i >= SERIAL_START && i < SERIAL_END) {
                serial = serial * 10 + digit;
            }
        }
        return (int) (serial % LANES);
    }

    static String answer(String sscc) {
        return "lane=" + laneFor(sscc);
    }
}
