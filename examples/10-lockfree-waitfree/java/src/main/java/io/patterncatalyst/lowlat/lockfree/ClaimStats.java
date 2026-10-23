package io.patterncatalyst.lowlat.lockfree;

/**
 * One producer's counters. Each producer owns one, so counting costs no shared write. Padded on
 * both sides by inheritance (HotSpot lays superclass fields out first) with 128 bytes, the width the
 * JDK's own {@code @Contended} uses, which covers the adjacent-line prefetch pair; {@code @Contended}
 * itself needs {@code -XX:-RestrictContended} for application classes.
 */
final class ClaimStats extends StatsLayout.Counters {

    @SuppressWarnings("unused")
    private long q01, q02, q03, q04, q05, q06, q07, q08, q09, q10, q11, q12, q13, q14, q15, q16;
}
