package io.patterncatalyst.lowlat.ch12;

/**
 * Wiring skeleton for the open-loop client: request {@code i} is due at a fixed offset from the
 * start whatever happened to the earlier ones, so latency is measured from the intended send time.
 */
public final class OpenLoopSchedule {

    private static final long NANOS_PER_SECOND = 1_000_000_000L;

    private OpenLoopSchedule() {}

    public static long intendedSendNanos(long startNanos, long index, long ratePerSecond) {
        return startNanos + index * NANOS_PER_SECOND / ratePerSecond;
    }
}
