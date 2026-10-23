package io.patterncatalyst.lowlat.eliminating;

import java.math.BigInteger;
import java.util.Random;

/**
 * Seeded barcodes for the working sets: distinct SSCC-18 keys as text (the node map's key) and packed
 * (the primitive map's key), in insertion order or in a shuffled lookup order.
 */
public final class Keys {

    static final long SSCC_SPACE = 1_000_000_000_000_000_000L; // 10^18 values of 18 digits
    private static final BigInteger STRIDE = BigInteger.valueOf(1_442_695_040_888_963_407L); // odd, not a multiple of 5
    private static final BigInteger SPACE = BigInteger.valueOf(SSCC_SPACE);

    private final String[] text;
    private final long[] packed;

    private Keys(String[] text, long[] packed) {
        this.text = text;
        this.packed = packed;
    }

    /** Key number {@code i} of a seeded family: (i + seed offset) * odd multiplier mod 10^18; distinct for distinct i. */
    static long ssccOf(long seed, long i) {
        return BigInteger.valueOf(i + seed * 0x9E3779B1L).multiply(STRIDE).mod(SPACE).longValueExact();
    }

    /** {@code n} distinct keys in insertion order. */
    public static Keys make(int n, long seed) {
        String[] text = new String[n];
        long[] packed = new long[n];
        for (int i = 0; i < n; i++) {
            packed[i] = ssccOf(seed, i);
            text[i] = Sscc.format(packed[i]);
        }
        return new Keys(text, packed);
    }

    /** The same {@code n} keys visited in a seeded random order: lookups into a table filled in insertion order. */
    public static Keys makeLookup(int n, long seed, long orderSeed) {
        int[] order = new int[n];
        for (int i = 0; i < n; i++) {
            order[i] = i;
        }
        Random rng = new Random(orderSeed);
        for (int i = n - 1; i > 0; i--) { // Fisher-Yates
            int j = rng.nextInt(i + 1);
            int t = order[i];
            order[i] = order[j];
            order[j] = t;
        }
        String[] text = new String[n];
        long[] packed = new long[n];
        for (int i = 0; i < n; i++) {
            packed[i] = ssccOf(seed, order[i]);
            text[i] = Sscc.format(packed[i]);
        }
        return new Keys(text, packed);
    }

    public int size() {
        return packed.length;
    }

    public String text(int i) {
        return text[i];
    }

    public long packed(int i) {
        return packed[i];
    }
}
