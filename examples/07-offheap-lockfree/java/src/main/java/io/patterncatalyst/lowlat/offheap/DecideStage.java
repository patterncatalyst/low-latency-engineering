package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.Completion;
import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.v1.DivertCommand;
import io.patterncatalyst.lowlat.line.v1.Lane;
import java.io.IOException;
import java.io.PrintStream;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Everything the decide thread does for one parcel, in order:
 *
 * <ol>
 *   <li>record the hand-off latency: pickup time minus the receive thread's stamp;
 *   <li>look the parcel up in the manifest, if the run has one;
 *   <li>decide the lane and send the divert command on the {@link CommandChannel};
 *   <li>complete the parcel: the end-to-end latency, intended emit to command sent;
 *   <li>append the audit record to the journal, if the run has one.
 * </ol>
 *
 * The journal comes after the command and after the completion, so an append never delays the
 * divert it describes; a slow append can still delay the next parcel's pickup, which the
 * hand-off report shows.
 *
 * <p>This thread owns the {@link Completion} (see its ownership rule): it is the only caller of
 * {@code complete}, and the join in {@link HandOff#close()} publishes what it recorded.
 */
final class DecideStage implements ScanSink {

    /** Scanner reads below this confidence go to the exception lane for a person to look at. */
    static final int MIN_CONFIDENCE_PERMILLE = 500;

    /** Encoder ticks between the scanner and the diverter: 1.2 m at the simulator's 1000 pulses per metre. */
    static final long DIVERT_DISTANCE_TICKS = 1_200;

    private final Completion done;
    private final CommandChannel commands;
    private final Journal journal; // null: no journal stage
    private final Manifest manifest; // null: no manifest stage
    private final PrintStream out;

    private final SplitRecorder handoff;
    private final SplitRecorder journalAppend;
    private final SplitRecorder manifestLookup;

    private final AtomicLong handled = new AtomicLong();
    private long count; // decide thread only; published through handled
    private long manifestHits;
    private long exceptionLane;

    DecideStage(Completion done, CommandChannel commands, Journal journal, Manifest manifest, String example,
            String variant, long window, PrintStream out) {
        this.done = done;
        this.commands = commands;
        this.journal = journal;
        this.manifest = manifest;
        this.out = out;
        this.handoff = new SplitRecorder(example, variant + "-handoff", window);
        this.journalAppend = new SplitRecorder(example, variant + "-journal-append", window);
        this.manifestLookup = new SplitRecorder(example, variant + "-manifest-lookup", window);
    }

    /**
     * Prints this thread's id on one parseable line, {@code decide-thread pid=P tid=T}, so a
     * script can read {@code /proc/P/task/T/status} (context switches) from outside. The kernel's
     * id for the calling thread is the target of {@code /proc/thread-self}, which Java has no
     * other portable way to ask for: {@code Thread.threadId()} is the JVM's own number.
     */
    @Override
    public void onStart() {
        try {
            String self = Files.readSymbolicLink(Path.of("/proc/thread-self")).toString(); // "PID/task/TID"
            String pid = self.substring(0, self.indexOf('/'));
            String tid = self.substring(self.lastIndexOf('/') + 1);
            out.println("decide-thread pid=" + pid + " tid=" + tid);
            out.flush();
            if (journal != null) {
                journal.bindToDecideThread();
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    @Override
    public void onScan(ScanView scan, long pickupNs) {
        long seq = scan.seq();
        handoff.record(seq, pickupNs - scan.rxNs());

        boolean onManifest = true;
        if (manifest != null) {
            long t0 = System.nanoTime();
            String destination = manifest.destination(scan.serial());
            manifestLookup.record(seq, System.nanoTime() - t0);
            onManifest = destination != null;
            if (onManifest) {
                manifestHits++;
            }
        }

        Lane lane = laneFor(scan, onManifest);
        if (lane == Lane.LANE_EXCEPTION) {
            exceptionLane++;
        }
        long decidedNs = System.nanoTime();
        DivertCommand command = DivertCommand.newBuilder()
                .setSeq(seq)
                .setLane(lane)
                .setDeadlineEncoderTick(scan.encoderTick() + DIVERT_DISTANCE_TICKS)
                .setDecidedNs(decidedNs)
                .build();
        try {
            commands.send(command);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        done.complete(seq, scan.intendedNs(), System.nanoTime());

        if (journal != null) {
            long t0 = System.nanoTime();
            journal.append(scan, decidedNs, lane.getNumber());
            journalAppend.record(seq, System.nanoTime() - t0);
        }
        handled.setRelease(++count);
    }

    /**
     * The lane for a scanned parcel: the exception lane when the read is doubtful or the parcel is
     * not on the manifest, otherwise one of the eight sort lanes by serial reference, the rule
     * {@code Lanes.laneOf} applies to the barcode.
     */
    static Lane laneFor(ScanView scan, boolean onManifest) {
        if (!onManifest || scan.confidencePermille() < MIN_CONFIDENCE_PERMILLE) {
            return Lane.LANE_EXCEPTION;
        }
        return Lane.forNumber(Lane.LANE_1_VALUE + (int) (scan.serial() % Lanes.LANES));
    }

    /** Parcels fully handled so far, safe to read from any thread. */
    long handled() {
        return handled.getAcquire();
    }

    /** Read the recorders and counters below only after {@link HandOff#close()} has joined the decide thread. */
    SplitRecorder handoff() {
        return handoff;
    }

    SplitRecorder journalAppend() {
        return journalAppend;
    }

    SplitRecorder manifestLookup() {
        return manifestLookup;
    }

    long manifestHits() {
        return manifestHits;
    }

    long exceptionLane() {
        return exceptionLane;
    }
}
