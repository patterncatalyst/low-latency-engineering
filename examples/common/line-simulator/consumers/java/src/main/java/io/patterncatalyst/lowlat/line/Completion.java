package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;

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
 * receiver's {@code begin} sets the seq the two-argument form uses for its error message and
 * its window).
 *
 * <p><b>Cache lines.</b> The receive thread writes the seq for every parcel and the owner writes
 * the count and the done times for every parcel. The seq lives in a {@link SeqCell} and the
 * owner's fields in a {@link DoneCell}; each is padded with 128 bytes on both sides. 128 rather
 * than 64 because the L2 spatial prefetcher on current Intel cores pulls adjacent line pairs, and
 * it is the width the JDK's own {@code @Contended} uses ({@code ContendedPaddingWidth}). The
 * receiver caches the {@link SeqCell} once and calls {@link #begin(SeqCell, long)}, so the receive
 * thread never loads this object's fields per parcel. A hand-off to a decide thread therefore
 * adds no line ping-pong to the path Ch7 measures.
 */
public final class Completion {

    private static final VarHandle SEQ;

    static {
        try {
            SEQ = MethodHandles.lookup().findVarHandle(SeqCell.class, "value", long.class);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private final LatencyRecorder recorder;
    private final WindowedRecorders windows; // null when the run has no window
    // Written by the receive thread per parcel, read by an owner thread for the error message and
    // the window of the two-argument complete: opaque access is race-free without the fence a
    // volatile write costs on the measured path.
    private final SeqCell seq = new SeqCell();
    // Written by the owner per parcel; read by others only after the owner is joined.
    private final DoneCell done = new DoneCell();

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
        complete((long) SEQ.getOpaque(seq), intendedEmitNs, doneNs);
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
        if (done.count++ == 0) {
            done.firstDoneNs = doneNs;
        }
        done.lastDoneNs = doneNs;
    }

    /** Parcels completed so far. */
    public long count() {
        return done.count;
    }

    /** {@code doneNs} of the first completion (0 when none). */
    public long firstDoneNs() {
        return done.firstDoneNs;
    }

    /** {@code doneNs} of the latest completion. */
    public long lastDoneNs() {
        return done.lastDoneNs;
    }

    /** The cell the receiver passes to {@link #begin(SeqCell, long)}; it caches this once. */
    SeqCell seqCell() {
        return seq;
    }

    /**
     * The receiver sets the seq being handled (error message and window of the two-argument form).
     * Static and taking the cell, so the receive thread does not touch the {@code Completion}
     * object the owner thread writes through.
     */
    static void begin(SeqCell cell, long seq) {
        SEQ.setOpaque(cell, seq);
    }

    // Padding by inheritance: HotSpot lays superclass fields out before subclass fields, so a
    // cell's fields have 128 bytes of padding before them (Lead) and after them (the final
    // subclass). 128 bytes is the JDK's @Contended width (ContendedPaddingWidth) and covers the
    // adjacent-line prefetch pair. @Contended itself needs -XX:-RestrictContended for application
    // classes; this works without flags.
    @SuppressWarnings("unused")
    static class Lead {
        long p01, p02, p03, p04, p05, p06, p07, p08, p09, p10, p11, p12, p13, p14, p15, p16;
    }

    static class Value extends Lead {
        long value;
    }

    @SuppressWarnings("unused")
    static final class SeqCell extends Value {
        long q01, q02, q03, q04, q05, q06, q07, q08, q09, q10, q11, q12, q13, q14, q15, q16;
    }

    static class Counters extends Lead {
        long count;
        long firstDoneNs;
        long lastDoneNs;
    }

    @SuppressWarnings("unused")
    static final class DoneCell extends Counters {
        long q01, q02, q03, q04, q05, q06, q07, q08, q09, q10, q11, q12, q13, q14, q15, q16;
    }
}
