package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;

/**
 * Where a {@link ParcelHandler} reports that a parcel is done. Completing records
 * {@code doneNs - intended_emit_ns}, so a handler may complete inside {@code onParcel}
 * (per-parcel) or later (a batch keeps {@code event.getIntendedEmitNs()} and completes every
 * held parcel when the batch is full). Also keeps the first and last done time, for
 * throughput. Not thread-safe: the receive thread owns it.
 */
public final class Completion {

    private final LatencyRecorder recorder;
    private long seq;
    private long count;
    private long firstDoneNs;
    private long lastDoneNs;

    Completion(LatencyRecorder recorder) {
        this.recorder = recorder;
    }

    /** Done now: reads {@link System#nanoTime()}. */
    public void complete(ParcelEvent event) {
        complete(event.getIntendedEmitNs(), System.nanoTime());
    }

    /**
     * Done at {@code doneNs} (one clock read can serve a whole batch).
     *
     * @throws LineReceiver.NegativeLatencyException if the latency is negative: the producer
     *     and this JVM are not on one monotonic clock
     */
    public void complete(long intendedEmitNs, long doneNs) {
        long latencyNs = doneNs - intendedEmitNs;
        if (latencyNs < 0) {
            throw new LineReceiver.NegativeLatencyException("negative latency " + latencyNs + " ns for seq "
                    + seq + ": intended_emit_ns is ahead of this JVM's System.nanoTime(); "
                    + "producer and consumer must run on one host (one CLOCK_MONOTONIC)");
        }
        recorder.record(latencyNs);
        if (count++ == 0) {
            firstDoneNs = doneNs;
        }
        lastDoneNs = doneNs;
    }

    /** Parcels completed so far. */
    public long count() {
        return count;
    }

    /** {@code doneNs} of the first completion (0 when none). */
    public long firstDoneNs() {
        return firstDoneNs;
    }

    /** {@code doneNs} of the latest completion. */
    public long lastDoneNs() {
        return lastDoneNs;
    }

    /** The receiver sets the seq being handled, for the error message. */
    void begin(long seq) {
        this.seq = seq;
    }
}
