package io.patterncatalyst.lowlat.eliminating;

import java.util.Random;

/**
 * Seeded barcodes for the working sets: distinct SSCC-18 keys as text (the node map's key) and packed
 * (the primitive map's key), in insertion order or in a shuffled lookup order.
 */
public final class Keys {

    static final long SSCC_SPACE = 1_000_000_000_000_000_000L; // 10^18 values of 18 digits
    private static final long STRIDE = 1_442_695_040_888_963_407L; // odd, not a multiple of 5

    private final String[] text;
    private final long[] packed;

    private Keys(String[] text, long[] packed) {
        this.text = text;
        this.packed = packed;
    }

    /**
     * Key number {@code i} of a seeded family: (i + seed offset) * odd multiplier mod 10^18; distinct for distinct i.
     * The 128-bit product is reduced with long arithmetic only (shift and add, 60 steps), so building the working
     * sets allocates nothing but the keys themselves: no collection runs while the map under test is built.
     */
    static long ssccOf(long seed, long i) {
        long a = Math.floorMod(i + seed * 0x9E3779B1L, SSCC_SPACE);
        long b = STRIDE % SSCC_SPACE;
        long product = 0;
        for (int bit = 62; bit >= 0; bit--) { // product = a * b mod 10^18, high bit of a first; every term < 3 * 10^18
            product = product << 1;
            if (product >= SSCC_SPACE) {
                product -= SSCC_SPACE;
            }
            if ((a >>> bit & 1) != 0) {
                product += b;
                if (product >= SSCC_SPACE) {
                    product -= SSCC_SPACE;
                }
            }
        }
        return product;
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
