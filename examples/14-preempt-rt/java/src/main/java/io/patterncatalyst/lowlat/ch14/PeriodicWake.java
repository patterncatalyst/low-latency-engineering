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

    /** Wakes recorded, and periods skipped inside the run window: samples + missedPeriods = periods in the window. */
    record Result(long samples, long missedPeriods) {
    }

    /**
     * The first deadline at or after {@code now} on the grid {@code deadline + k * period}: it steps over a grid
     * point only when {@code now} is strictly after it (cyclictest's rule), so a wake exactly on the next deadline
     * is not a miss.
     */
    static long nextDeadline(long deadline, long now, long period) {
        long next = deadline + period;
        if (now - next > 0) {
            next += Math.ceilDiv(now - next, period) * period;
        }
        return next;
    }

    /** How many of {@code skipped} grid points starting at {@code first} fall at or before {@code end}. */
    static long missedInWindow(long skipped, long first, long end, long period) {
        if (end - first < 0) {
            return 0;
        }
        return Math.min(skipped, (end - first) / period + 1);
    }

    /**
     * Wakes on every deadline up to {@code start + durationNanos}, passing each wake-up's lateness (actual minus
     * intended, never negative) to {@code lateness}. A stalled run ends on time with fewer samples instead of
     * overrunning (as {@code cyclictest -D} does); samples + missed periods equals duration / period when the run
     * completes. An interrupt stops the run: {@code parkNanos} returns at once while the flag is set, so looping
     * on would spin. The flag stays set for the caller.
     */
    public Result run(long durationNanos, LongConsumer lateness) {
        long start = clock.getAsLong();
        long end = start + durationNanos;
        long deadline = start + periodNanos;
        long samples = 0;
        long missed = 0;
        while (deadline - end <= 0) {
            long left;
            while ((left = remaining(deadline, clock.getAsLong())) > 0) {
                if (Thread.currentThread().isInterrupted()) {
                    return new Result(samples, missed);
                }
                LockSupport.parkNanos(left);
            }
            long woke = clock.getAsLong();
            lateness.accept(Math.max(0L, woke - deadline));
            samples++;
            long next = nextDeadline(deadline, woke, periodNanos);
            long skipped = (next - deadline) / periodNanos - 1;
            missed += missedInWindow(skipped, deadline + periodNanos, end, periodNanos);
            deadline = next;
        }
        return new Result(samples, missed);
    }
}
