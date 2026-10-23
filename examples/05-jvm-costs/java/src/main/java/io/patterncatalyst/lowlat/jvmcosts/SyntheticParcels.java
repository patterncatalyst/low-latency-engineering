package io.patterncatalyst.lowlat.jvmcosts;

import io.patterncatalyst.lowlat.line.v1.Dimensions;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.util.SplittableRandom;

/**
 * Parcels shaped like the simulator's (log-normal weight around 2 kg, carton sizes, 97 % good scans) for
 * the in-process warm-up replay and the JMH benchmarks. Seeded, so a run repeats.
 */
public final class SyntheticParcels {

    private static final long SERIAL_LIMIT = 1_000_000_000L;
    private static final double MEDIAN_WEIGHT_G = 2_000;
    private static final double WEIGHT_SIGMA = 0.6;
    private static final int MAX_WEIGHT_G = 60_000;

    private final SplittableRandom random;

    public SyntheticParcels(long seed) {
        this.random = new SplittableRandom(seed);
    }

    /** Parcel {@code seq}, due at {@code intendedEmitNs}, at belt position {@code encoderTick}. */
    public ParcelEvent next(long seq, long intendedEmitNs, long encoderTick) {
        boolean goodScan = random.nextInt(100) < 97;
        double weightG = MEDIAN_WEIGHT_G * Math.exp(WEIGHT_SIGMA * random.nextGaussian());
        return ParcelEvent.newBuilder()
                .setSeq(seq)
                .setIntendedEmitNs(intendedEmitNs)
                .setActualEmitNs(intendedEmitNs)
                .setEncoderTick(encoderTick)
                .setBarcode(sscc(seq))
                .setWeightG((int) Math.min(weightG, MAX_WEIGHT_G))
                .setDims(Dimensions.newBuilder()
                        .setLengthMm(random.nextInt(150, 1_200))
                        .setWidthMm(random.nextInt(100, 700))
                        .setHeightMm(random.nextInt(50, 500)))
                .setScanConfidencePermille(goodScan ? random.nextInt(950, 1_001) : random.nextInt(300, 701))
                .build();
    }

    /** {@code count} parcels with consecutive sequence numbers, for a benchmark's input array. */
    public static ParcelEvent[] batch(int count, long seed) {
        SyntheticParcels parcels = new SyntheticParcels(seed);
        ParcelEvent[] events = new ParcelEvent[count];
        for (int i = 0; i < count; i++) {
            events[i] = parcels.next(i, 0, i * 2L);
        }
        return events;
    }

    /** An SSCC-18 for {@code serial}: prefix, 9-digit serial reference, GS1 mod-10 check digit. */
    static String sscc(long serial) {
        String body = "00614141%09d".formatted(serial % SERIAL_LIMIT);
        return body + checkDigit(body);
    }

    /** GS1 mod-10 check digit of the 17 digits in {@code body}: the rightmost digit weighs 3, then 1, 3, 1... */
    static int checkDigit(String body) {
        int sum = 0;
        for (int i = 0; i < body.length(); i++) {
            int digit = body.charAt(i) - '0';
            sum += (body.length() - i) % 2 == 1 ? 3 * digit : digit;
        }
        return (10 - sum % 10) % 10;
    }
}
