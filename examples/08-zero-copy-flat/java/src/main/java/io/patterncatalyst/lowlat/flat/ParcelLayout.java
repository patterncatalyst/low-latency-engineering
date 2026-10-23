package io.patterncatalyst.lowlat.flat;

import static java.lang.foreign.ValueLayout.JAVA_BYTE;
import static java.lang.foreign.ValueLayout.JAVA_INT_UNALIGNED;
import static java.lang.foreign.ValueLayout.JAVA_LONG_UNALIGNED;
import static java.lang.foreign.ValueLayout.JAVA_SHORT_UNALIGNED;

import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemoryLayout.PathElement;
import java.lang.foreign.StructLayout;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.VarHandle;
import java.nio.ByteOrder;

/**
 * The flat record of {@code contracts/flat/parcel-v1} as an FFM {@link StructLayout}. The C++
 * header {@code parcel_v1.hpp} is the source of truth; this class repeats its field order and
 * widths and derives every offset from the layout, so a mismatch cannot hide in a hand-typed
 * constant. {@code ParcelLayoutTest} compares the derived offsets with the header's
 * {@code static_assert(offsetof(...))} lines and the README table.
 *
 * <p>Every value layout is unaligned: the record arrives in a UDP receive buffer, and a layout
 * that insisted on 8-byte alignment would reject (or silently mis-handle) a buffer that is not.
 * The wire is little-endian whatever the host is, so the byte order is part of each layout.
 */
final class ParcelLayout {

    static final int SCHEMA_ID = 1;
    static final int VERSION = 1;
    static final int SIZE = 80;
    static final int BARCODE_LEN = 18;

    private static final ByteOrder LE = ByteOrder.LITTLE_ENDIAN;
    private static final ValueLayout.OfShort U16 = JAVA_SHORT_UNALIGNED.withOrder(LE);
    private static final ValueLayout.OfInt U32 = JAVA_INT_UNALIGNED.withOrder(LE);
    private static final ValueLayout.OfLong U64 = JAVA_LONG_UNALIGNED.withOrder(LE);

    /** Field order and names as in parcel_v1.hpp. */
    static final StructLayout LAYOUT = MemoryLayout.structLayout(
            U16.withName("schema_id"),
            U16.withName("version"),
            U32.withName("weight_g"),
            U64.withName("seq"),
            U64.withName("intended_emit_ns"),
            U64.withName("actual_emit_ns"),
            U64.withName("encoder_tick"),
            U32.withName("length_mm"),
            U32.withName("width_mm"),
            U32.withName("height_mm"),
            U32.withName("scan_confidence_permille"),
            MemoryLayout.sequenceLayout(BARCODE_LEN, JAVA_BYTE).withName("barcode"),
            MemoryLayout.paddingLayout(6).withName("reserved"));

    // Coordinates of every handle: (MemorySegment segment, long baseOffset of the record).
    static final VarHandle SCHEMA_ID_H = field("schema_id");
    static final VarHandle VERSION_H = field("version");
    static final VarHandle WEIGHT_G = field("weight_g");
    static final VarHandle SEQ = field("seq");
    static final VarHandle INTENDED_EMIT_NS = field("intended_emit_ns");
    static final VarHandle ACTUAL_EMIT_NS = field("actual_emit_ns");
    static final VarHandle ENCODER_TICK = field("encoder_tick");
    static final VarHandle LENGTH_MM = field("length_mm");
    static final VarHandle WIDTH_MM = field("width_mm");
    static final VarHandle HEIGHT_MM = field("height_mm");
    static final VarHandle SCAN_CONFIDENCE_PERMILLE = field("scan_confidence_permille");

    /** The barcode is a byte run, read in place at this offset. */
    static final long BARCODE_AT = offset("barcode");

    static {
        if (LAYOUT.byteSize() != SIZE) { // not an assert: -ea is off by default
            throw new ExceptionInInitializerError("parcel-v1 layout is " + LAYOUT.byteSize() + " bytes, expected " + SIZE);
        }
    }

    private ParcelLayout() {
    }

    static long offset(String field) {
        return LAYOUT.byteOffset(PathElement.groupElement(field));
    }

    private static VarHandle field(String name) {
        return LAYOUT.varHandle(PathElement.groupElement(name));
    }
}
