package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Where a {@link ParcelHandler} reports that a parcel is done. Completing records
 * {@code doneNs - intended_emit_ns}, so a handler may complete inside {@code onParcel}
 * (per-parcel) or later (a batch keeps {@code event.getIntendedEmitNs()} and completes every
 * held parcel when the batch is full). Also keeps the first and last done time, for
 * throughput.
 *
 * <p><b>Ownership.</b> Completion is single-writer: at any moment exactly one thread calls
 * {@code complete}. That thread is the receive thread unless the handler moves ownership, for
 * example to a decide thread (Ch7): the handler keeps the {@code Completion} it was given,
 * starts a thread that calls {@code complete}, and in {@link EventHandler#drain} stops and
 * {@linkplain Thread#join() joins} it. The receiver reads {@link #count()} and the done times,
 * and the report reads the recorder, only after {@code drain} returns, so the join is the
 * happens-before edge that publishes everything the owner wrote; no lock or volatile is needed
 * on the recording path. Once the handler has handed over, the receive thread must not call
 * {@code complete}, and the owner must use the overloads that carry the sequence number (the
 * receiver's {@code begin} only feeds the error message of the two-argument form).
 */
public final class Completion {

    private final LatencyRecorder recorder;
    private final WindowedRecorders windows; // null when the run has no window
    // Written by the receive thread per parcel, read by an owner thread only for an error message:
    // opaque access is race-free without the fence a volatile write costs on the measured path.
    private final AtomicLong seq = new AtomicLong();
    private long count;
    private long firstDoneNs;
    private long lastDoneNs;

    Completion(LatencyRecorder recorder) {
        this(recorder, null);
    }

    Completion(LatencyRecorder recorder, WindowedRecorders windows) {
        this.recorder = recorder;
        this.windows = windows;
    }

    /** Done now: reads {@link System#nanoTime()}. */
    public void complete(ParcelEvent event) {
        complete(event.getSeq(), event.getIntendedEmitNs(), System.nanoTime());
    }

    /**
     * Done at {@code doneNs} (one clock read can serve a whole batch), for the parcel the receiver
     * is handling now. A batch that completes parcels later, or a completion on another thread,
     * must use {@link #complete(long, long, long)} so a windowed run counts the right parcel.
     *
     * @throws EventReceiver.NegativeLatencyException if the latency is negative: the producer
     *     and this JVM are not on one monotonic clock
     */
    public void complete(long intendedEmitNs, long doneNs) {
        complete(seq.getOpaque(), intendedEmitNs, doneNs);
    }

    /**
     * As {@link #complete(long, long)} for parcel {@code seq}, which decides the window the
     * latency is recorded in.
     */
    public void complete(long seq, long intendedEmitNs, long doneNs) {
        long latencyNs = doneNs - intendedEmitNs;
        if (latencyNs < 0) {
            throw new EventReceiver.NegativeLatencyException("negative latency " + latencyNs + " ns for seq "
                    + seq + ": intended_emit_ns is ahead of this JVM's System.nanoTime(); "
                    + "producer and consumer must run on one host (one CLOCK_MONOTONIC)");
        }
        recorder.record(latencyNs);
        if (windows != null) {
            windows.record(seq, latencyNs);
        }
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
        this.seq.setOpaque(seq);
    }
}
