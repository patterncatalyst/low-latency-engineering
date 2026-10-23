package io.patterncatalyst.lowlat.lockfree;

/** The padded layout of {@link ClaimStats}, kept in a class of its own so that no class extends its own member. */
final class StatsLayout {

    private StatsLayout() {
    }

    @SuppressWarnings("unused")
    static class Lead {
        long p01, p02, p03, p04, p05, p06, p07, p08, p09, p10, p11, p12, p13, p14, p15, p16;
    }

    static class Counters extends Lead {
        long claims;
        long steps; // lock acquisitions, CAS attempts or getAndIncrements executed
        long casFailures; // failed compareAndSet attempts (the CAS loop only)
        long maxRetries; // most failed attempts inside one claim
        long roomLimit; // ClaimLog's cache of how far ahead of the consumer this producer may write
    }
}
