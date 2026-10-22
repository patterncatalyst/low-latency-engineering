package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.Completion;
import io.patterncatalyst.lowlat.line.EventHandler;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.io.PrintStream;
import java.time.Duration;
import java.util.concurrent.locks.LockSupport;

/**
 * The receive thread's whole job for one parcel: stamp the receive time and hand the parcel
 * over. It never completes a parcel: the {@link Completion} belongs to the decide thread
 * ({@link DecideStage}), and {@link #drain} is where the receive thread waits for it and joins it.
 */
final class ScanHandler implements EventHandler<ParcelEvent> {

    private static final Duration DRAIN_TIMEOUT = Duration.ofSeconds(60);

    private final HandOff handOff;
    private final DecideStage stage;
    private final long holdMs;
    private final PrintStream out;
    private long published;
    private long overflow;

    ScanHandler(HandOff handOff, DecideStage stage, long holdMs, PrintStream out) {
        this.handOff = handOff;
        this.stage = stage;
        this.holdMs = holdMs;
        this.out = out;
    }

    @Override
    public void onParcel(ParcelEvent event, Completion done) {
        long rxNs = System.nanoTime();
        if (handOff.publish(event, rxNs)) {
            published++;
        } else {
            overflow++; // the hand-off is full: the parcel is lost, and the count shows it
        }
    }

    /**
     * Waits until the decide thread has handled everything published, prints the
     * {@code window-end} line, keeps the decide thread alive for the sampling hold and then
     * stops and joins it. A script reads the thread's context switches between the
     * {@code decide-thread} line and the {@code window-end} line plus the hold.
     */
    @Override
    public void drain(Completion done) {
        long deadline = System.nanoTime() + DRAIN_TIMEOUT.toNanos();
        while (stage.handled() < published) {
            if (handOff.failure() != null) {
                throw new IllegalStateException("decide thread died", handOff.failure());
            }
            if (System.nanoTime() > deadline) {
                throw new IllegalStateException("decide thread handled " + stage.handled() + " of " + published);
            }
            LockSupport.parkNanos(1_000_000); // after the run: a poll, not a spin
        }
        out.println("window-end handled=" + stage.handled());
        out.flush();
        if (holdMs > 0) {
            try {
                Thread.sleep(holdMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        handOff.close();
    }

    long published() {
        return published;
    }

    long overflow() {
        return overflow;
    }
}
