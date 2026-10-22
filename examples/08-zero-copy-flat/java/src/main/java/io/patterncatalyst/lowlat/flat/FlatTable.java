package io.patterncatalyst.lowlat.flat;

import static java.lang.foreign.ValueLayout.JAVA_BYTE;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

import java.lang.foreign.Arena;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemoryLayout.PathElement;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.StructLayout;
import java.lang.invoke.VarHandle;

/**
 * The flat layout: the same fields as {@link ParcelState}, one struct per slot, packed back to
 * back in a single off-heap {@link MemorySegment}. A sweep walks memory in address order, so the
 * hardware prefetcher sees a stream; the {@link ObjectTable} sweep follows a pointer per slot.
 *
 * <p>The segment belongs to an {@link Arena}, so its lifetime is explicit and the memory is
 * released deterministically by {@link #close()}, not by the garbage collector. The arena is
 * confined: one thread builds, sweeps and closes the table.
 */
public final class FlatTable implements InFlightTable, AutoCloseable {

    /** 24 bytes, naturally aligned (the C++ twin is {@code ParcelState} in {@code flat_table.hpp}). */
    static final StructLayout STATE = MemoryLayout.structLayout(
            JAVA_LONG.withName("seq"),
            JAVA_LONG.withName("encoder_tick"),
            JAVA_INT.withName("weight_g"),
            JAVA_BYTE.withName("lane"),
            JAVA_BYTE.withName("state"),
            MemoryLayout.paddingLayout(2));

    private static final long SLOT_BYTES = STATE.byteSize();

    // Coordinates: (MemorySegment segment, long baseOffset of the slot). The handles come from the one
    // struct, not from a sequence layout: a handle that spans a sequence checks that the whole
    // enclosing layout fits in the segment, and the sequence's length is only known per table.
    private static final VarHandle SEQ = STATE.varHandle(PathElement.groupElement("seq"));
    private static final VarHandle ENCODER_TICK = STATE.varHandle(PathElement.groupElement("encoder_tick"));
    private static final VarHandle WEIGHT_G = STATE.varHandle(PathElement.groupElement("weight_g"));
    private static final VarHandle LANE = STATE.varHandle(PathElement.groupElement("lane"));
    private static final VarHandle STATE_H = STATE.varHandle(PathElement.groupElement("state"));

    private final Arena arena;
    private final MemorySegment slots;
    private final int size;

    public FlatTable(int size) {
        this.arena = Arena.ofConfined();
        this.slots = arena.allocate(MemoryLayout.sequenceLayout(size, STATE)); // zeroed
        this.size = size;
    }

    /** Copies a table of objects into flat slots, keeping the slot order. */
    public static FlatTable copyOf(ParcelState[] states) {
        FlatTable table = new FlatTable(states.length);
        for (int i = 0; i < states.length; i++) {
            table.set(i, states[i]);
        }
        return table;
    }

    public void set(int slot, ParcelState parcel) {
        long at = slot * SLOT_BYTES;
        SEQ.set(slots, at, parcel.seq());
        ENCODER_TICK.set(slots, at, parcel.encoderTick());
        WEIGHT_G.set(slots, at, parcel.weightG());
        LANE.set(slots, at, parcel.lane());
        STATE_H.set(slots, at, parcel.state());
    }

    /** The slot as an object, for tests; allocates. */
    public ParcelState get(int slot) {
        long at = slot * SLOT_BYTES;
        return new ParcelState(
                (long) SEQ.get(slots, at),
                (long) ENCODER_TICK.get(slots, at),
                (int) WEIGHT_G.get(slots, at),
                (byte) LANE.get(slots, at),
                (byte) STATE_H.get(slots, at));
    }

    /** Bytes the table occupies off-heap. */
    public long byteSize() {
        return slots.byteSize();
    }

    @Override
    public int size() {
        return size;
    }

    @Override
    public long sweepDue(long dueTick) {
        long weight = 0;
        for (long at = 0, end = size * SLOT_BYTES; at < end; at += SLOT_BYTES) {
            if ((long) ENCODER_TICK.get(slots, at) <= dueTick && (byte) STATE_H.get(slots, at) == IN_FLIGHT) {
                weight += (int) WEIGHT_G.get(slots, at);
            }
        }
        return weight;
    }

    @Override
    public void close() {
        arena.close();
    }
}
