package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.io.IOException;
import java.util.Arrays;

/**
 * Receives protobuf {@link ParcelEvent} datagrams and records {@code done_ns - intended_emit_ns}:
 * an {@link EventReceiver} with the {@link Decoder#protobuf() protobuf decoder}, plus the
 * example 00 handler. A consumer of another wire format builds an {@code EventReceiver} with
 * its own {@link Decoder}.
 */
public final class LineReceiver extends EventReceiver<ParcelEvent> {

    private final long[] laneCounts = new long[Lanes.LANES];

    public LineReceiver(Config config) throws IOException {
        super(config, Decoder.protobuf());
    }

    public long[] laneCounts() {
        return laneCounts.clone();
    }

    /** Receives with the example 00 handler: the lane lookup, then done. Fills {@link #laneCounts()}. */
    public StopReason run() throws IOException {
        return run((event, done) -> {
            laneCounts[Lanes.laneOf(event.getBarcode())]++; // the Chapter 0 "handle" step
            done.complete(event);
        });
    }

    @Override
    String notes() {
        return super.notes() + "; lanes=" + Arrays.toString(laneCounts);
    }
}
