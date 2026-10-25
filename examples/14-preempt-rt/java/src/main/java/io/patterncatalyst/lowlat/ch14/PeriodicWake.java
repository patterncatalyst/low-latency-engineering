package io.patterncatalyst.lowlat.ch14;

import java.util.concurrent.locks.LockSupport;
import java.util.function.LongConsumer;
import java.util.function.LongSupplier;

/**
 * A periodic waker: sleeps to absolute deadlines on the {@code System.nanoTime()} scale and reports how late
 * each wake-up was.
 *
 * <p>{@link LockSupport#parkNanos(long)} takes a relative wait and may return early for no reason, so the loop
 * recomputes the remaining time from the clock after every return and parks again until the deadline has
 * passed. The next deadline is the previous deadline plus the period, never "now" plus the period, so a late
 * wake does not push every later one back.
 */
public final class PeriodicWake {

    private final long periodNanos;
    private final LongSupplier clock;

    public PeriodicWake(long periodNanos) {
        this(periodNanos, System::nanoTime);
    }

    /** The clock is a parameter so the arithmetic can be tested with a scripted clock. */
    PeriodicWake(long periodNanos, LongSupplier clock) {
        if (periodNanos <= 0) {
            throw new IllegalArgumentException("period must be positive: " + periodNanos);
        }
        this.periodNanos = periodNanos;
        this.clock = clock;
    }

    /** Nanoseconds left until {@code deadline}, or 0 when it has passed. {@code nanoTime} values compare by difference. */
    static long remaining(long deadline, long now) {
        return Math.max(0L, deadline - now);
    }

    /** The first deadline strictly after {@code now}, on the grid {@code deadline + k * period}. */
    static long nextDeadline(long deadline, long now, long period) {
        long next = deadline + period;
        if (next - now <= 0) {
            next += ((now - next) / period + 1) * period;
        }
        return next;
    }

    /**
     * Wakes {@code wakeups} times, passing each wake-up's lateness (actual minus intended, never negative) to
     * {@code lateness}. Returns the number of whole periods skipped because a wake came a period or more late.
     */
    public long run(int wakeups, LongConsumer lateness) {
        long deadline = clock.getAsLong() + periodNanos;
        long skipped = 0;
        for (int i = 0; i < wakeups; i++) {
            long left;
            while ((left = remaining(deadline, clock.getAsLong())) > 0) {
                LockSupport.parkNanos(left);
            }
            long woke = clock.getAsLong();
            lateness.accept(Math.max(0L, woke - deadline));
            long next = nextDeadline(deadline, woke, periodNanos);
            skipped += (next - deadline) / periodNanos - 1;
            deadline = next;
        }
        return skipped;
    }
}
