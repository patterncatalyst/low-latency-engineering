package io.patterncatalyst.lowlat.line;

/**
 * Tracks the {@code seq} stream. The simulator numbers parcels from 0 without gaps, so a jump
 * forward by more than one is that many lost datagrams, and a {@code seq} at or below the highest
 * seen is reordered or duplicated. Not thread-safe: one receive thread owns it.
 */
final class GapTracker {

    /** What one datagram's {@code seq} turned out to be. */
    enum Arrival { NEW, REORDERED }

    private long highest = -1; // before the first datagram, "seq -1" has been seen
    private long dropped;
    private long reordered;
    private long lastGap;
    private final long window; // 0: no window
    private long droppedBelowWindow;

    GapTracker() {
        this(0);
    }

    /** With a window, also counts the dropped parcels numbered below it. */
    GapTracker(long window) {
        this.window = window;
    }

    /** Observe one {@code seq}; the number of newly missing parcels is {@link #lastGap()}. */
    Arrival observe(long seq) {
        lastGap = 0;
        if (seq <= highest) {
            reordered++;
            return Arrival.REORDERED;
        }
        lastGap = seq - highest - 1;
        dropped += lastGap;
        long firstMissing = highest + 1;
        if (firstMissing < window) {
            droppedBelowWindow += Math.min(seq, window) - firstMissing;
        }
        highest = seq;
        return Arrival.NEW;
    }

    /** Parcels newly counted missing by the most recent {@link #observe}. */
    long lastGap() {
        return lastGap;
    }

    long dropped() {
        return dropped;
    }

    /** Dropped parcels numbered below the window (0 when there is none). */
    long droppedBelowWindow() {
        return droppedBelowWindow;
    }

    long reordered() {
        return reordered;
    }

    long highest() {
        return highest;
    }
}
