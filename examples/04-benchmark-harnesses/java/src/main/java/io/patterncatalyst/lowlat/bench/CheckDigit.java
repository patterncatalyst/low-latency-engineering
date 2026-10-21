package io.patterncatalyst.lowlat.bench;

/**
 * SSCC-18 GS1 mod-10 check digit, the same algorithm as the C++ line-simulator
 * ({@code sscc_check_digit}) and the Python {@code lowlat_bench.check_digit}.
 *
 * <p>Weights 3,1,3,1,... from the rightmost of the 17 digits; the check digit brings
 * the weighted sum up to a multiple of ten. The body is exactly 17 ASCII digits; the
 * loop does not validate each character, which keeps it a pure function the JIT can
 * remove when the result is unused.
 */
public final class CheckDigit {

    /** Number of digits in the SSCC body (the check digit is the 18th). */
    public static final int BODY_DIGITS = 17;

    private CheckDigit() {}

    public static int of(String digits17) {
        if (digits17.length() != BODY_DIGITS) {
            throw new IllegalArgumentException("SSCC body must be 17 digits, got '" + digits17 + "'");
        }
        int sum = 0;
        int weight = 3; // the digit next to the check digit weighs 3
        for (int i = BODY_DIGITS - 1; i >= 0; i--) {
            sum += (digits17.charAt(i) - '0') * weight;
            weight = 4 - weight; // 3 <-> 1
        }
        return (10 - sum % 10) % 10;
    }

    /**
     * The fixed prefix set shared by all three languages: prefix i = extension (i % 10),
     * company prefix 0614141, serial (i * 7919 + 13) % 10^9 zero-padded to nine digits.
     */
    public static String[] prefixes(int n) {
        String[] out = new String[n];
        for (int i = 0; i < n; i++) {
            out[i] = "%d0614141%09d".formatted(i % 10, ((long) i * 7919 + 13) % 1_000_000_000L);
        }
        return out;
    }
}
