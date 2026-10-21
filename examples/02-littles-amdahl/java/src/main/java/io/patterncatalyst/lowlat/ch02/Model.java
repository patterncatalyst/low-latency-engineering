package io.patterncatalyst.lowlat.ch02;

/**
 * The two laws of Ch2 as code. Both take a time-average or a time fraction as an input and
 * predict something else; neither is ever a latency result.
 */
public final class Model {

    private Model() {
    }

    /**
     * Amdahl's Law. {@code serialFraction} s is the share of the one-worker run that cannot be
     * parallelised (time inside the lock). With the parallel fraction p = 1 - s:
     * {@code S(n) = 1 / ((1 - p) + p / n) = 1 / (s + (1 - s) / n)}, bounded above by 1 / s.
     */
    public static double amdahlSpeedup(double serialFraction, int workers) {
        return 1.0 / (serialFraction + (1.0 - serialFraction) / workers);
    }

    /** Parcels due (by the belt's schedule) at or before {@code nowNs}; parcel 0 is due at t0. */
    public static long arrivalsBy(long nowNs, long t0Ns, long rateHz) {
        return nowNs < t0Ns ? 0 : (nowNs - t0Ns) * rateHz / 1_000_000_000L + 1;
    }

    /** Little's Law, L = lambda * W, with W in seconds. */
    public static double littlesL(double lambdaPerSecond, double wSeconds) {
        return lambdaPerSecond * wSeconds;
    }
}
