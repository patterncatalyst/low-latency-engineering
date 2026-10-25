package io.patterncatalyst.lowlat.ch12;

/** Sequence accounting for one camera: parcels are numbered from 0 without gaps. One receive thread owns it. */
final class SeqTracker {

    private final long expect;
    private long highest = -1;
    private long received;

    SeqTracker(long expect) {
        this.expect = expect;
    }

    /** True when {@code seq} is new; a repeat or a late arrival is not. */
    boolean observe(long seq) {
        if (seq <= highest) {
            return false;
        }
        highest = seq;
        received++;
        return true;
    }

    long received() {
        return received;
    }

    /** Parcels the camera was due to send and this side did not see. */
    long lost() {
        return Math.max(0, expect - received);
    }

    /** True once every parcel is accounted for: seen, or skipped by a later one. */
    boolean complete() {
        return highest + 1 >= expect;
    }
}
