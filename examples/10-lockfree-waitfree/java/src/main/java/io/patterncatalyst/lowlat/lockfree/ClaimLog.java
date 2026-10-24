package io.patterncatalyst.lowlat.lockfree;

import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.util.concurrent.atomic.AtomicLongArray;

/**
 * A multi-producer, single-consumer log: producers claim a sequence number, write the slot, then
 * publish it; the consumer reads the slots in sequence order.
 *
 * <p>Publication is a release store of {@code seq + 1} into the slot's stamp, and the consumer's
 * acquire load of the stamp is what makes the payload visible, so the payload array is plain data. A
 * producer never writes more than {@code capacity} slots ahead of the consumer (the log is a ring).
 *
 * <p>Claiming a number and publishing it are two steps. The claim can be wait-free and the consumer
 * still waits at a claimed-but-unpublished sequence for as long as its producer is stalled.
 */
final class ClaimLog {

    private final int mask;
    private final AtomicLongArray stamps;
    private final long[] payloads;
    private final SequenceClaim claim;
    private final PaddedCounter consumed = new PaddedCounter();

    ClaimLog(SequenceClaim claim, int capacity) {
        if (Integer.bitCount(capacity) != 1) {
            throw new IllegalArgumentException("capacity must be a power of two: " + capacity);
        }
        this.mask = capacity - 1;
        this.stamps = new AtomicLongArray(capacity);
        this.payloads = new long[capacity];
        this.claim = claim;
    }

    int capacity() {
        return mask + 1;
    }

    /** Producer: the next sequence number (the progress guarantee is the claim's). */
    long claim(ClaimStats stats) {
        return claim.claim(stats);
    }

    /** Producer: waits until the ring has room for {@code seq}, writes the payload and publishes the slot. */
    void publish(long seq, long payload, ClaimStats stats) {
        // A busy-spin with Thread.onSpinWait (PAUSE), not LockSupport.park: a park and unpark round trip costs
        // microseconds on a path whose claim takes nanoseconds, and the threads are pinned to cores of their
        // own. Same reason as the C++ log. A latency construct, not advice for general code.
        while (seq >= stats.roomLimit) {
            stats.roomLimit = consumed.getAcquire() + capacity();
            if (seq >= stats.roomLimit) {
                Thread.onSpinWait();
            }
        }
        int slot = (int) (seq & mask);
        payloads[slot] = payload;
        stamps.setRelease(slot, seq + 1);
    }

    /** The consumer's end; one thread only. */
    Reader reader() {
        return new Reader();
    }

    final class Reader {
        private long waitedNs;

        /** Waits until {@code seq} is published and returns its payload; {@link #waitedNs} says for how long. */
        long read(long seq) {
            int slot = (int) (seq & mask);
            waitedNs = 0;
            // A busy-spin with Thread.onSpinWait (PAUSE), not LockSupport.park: a park and unpark round trip costs
            // microseconds on a path whose claim takes nanoseconds, and the threads are pinned to cores of their
            // own. Same reason as the C++ log. A latency construct, not advice for general code.
            if (stamps.getAcquire(slot) != seq + 1) {
                long missedAt = System.nanoTime();
                while (stamps.getAcquire(slot) != seq + 1) {
                    Thread.onSpinWait();
                }
                waitedNs = System.nanoTime() - missedAt;
            }
            return payloads[slot];
        }

        /** 0 when the last slot was already there, otherwise the time from the first miss to the publication. */
        long waitedNs() {
            return waitedNs;
        }

        /** Hands the slot back to the producers. */
        void consumed(long seq) {
            consumed.setRelease(seq + 1);
        }
    }

    // The consumer's cursor, alone on its cache lines: written by the consumer for every slot, read by
    // the producers when they near the end of the ring. Padded by inheritance, as ClaimStats is.
    @SuppressWarnings("unused")
    static class Lead {
        long p01, p02, p03, p04, p05, p06, p07, p08, p09, p10, p11, p12, p13, p14, p15, p16;
    }

    static class Cursor extends Lead {
        long value;
    }

    @SuppressWarnings("unused")
    static final class PaddedCounter extends Cursor {
        private static final VarHandle VALUE;

        static {
            try {
                VALUE = MethodHandles.lookup().findVarHandle(Cursor.class, "value", long.class);
            } catch (ReflectiveOperationException e) {
                throw new ExceptionInInitializerError(e);
            }
        }

        long q01, q02, q03, q04, q05, q06, q07, q08, q09, q10, q11, q12, q13, q14, q15, q16;

        long getAcquire() {
            return (long) VALUE.getAcquire(this);
        }

        void setRelease(long v) {
            VALUE.setRelease(this, v);
        }
    }
}
