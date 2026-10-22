package io.patterncatalyst.lowlat.line;

import static java.lang.foreign.ValueLayout.JAVA_BYTE;
import static java.lang.foreign.ValueLayout.JAVA_INT_UNALIGNED;
import static java.lang.foreign.ValueLayout.JAVA_LONG_UNALIGNED;
import static java.lang.foreign.ValueLayout.JAVA_SHORT_UNALIGNED;

import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemoryLayout.PathElement;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.StructLayout;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * Test reader and writer for the flat record of {@code contracts/flat/parcel-v1}: a flyweight over
 * a {@link MemorySegment}, so reading a parcel allocates nothing. Ch8 builds the measured decoder
 * on the same layout; here it proves the {@link Decoder} seam and that Java reads the C++ bytes.
 */
final class FlatParcel {

    static final int SIZE = 80;
    static final int SCHEMA_ID = 1;
    static final int VERSION = 1;
    static final int BARCODE_LEN = 18;

    private static final ByteOrder LE = ByteOrder.LITTLE_ENDIAN;
    private static final ValueLayout.OfShort U16 = JAVA_SHORT_UNALIGNED.withOrder(LE);
    private static final ValueLayout.OfInt U32 = JAVA_INT_UNALIGNED.withOrder(LE);
    private static final ValueLayout.OfLong U64 = JAVA_LONG_UNALIGNED.withOrder(LE);

    /** The layout, in the order and with the names of parcel_v1.hpp. */
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

    private static long offset(String field) {
        return LAYOUT.byteOffset(PathElement.groupElement(field));
    }

    private static final long SCHEMA_ID_AT = offset("schema_id");
    private static final long VERSION_AT = offset("version");
    private static final long WEIGHT_AT = offset("weight_g");
    private static final long SEQ_AT = offset("seq");
    private static final long INTENDED_AT = offset("intended_emit_ns");
    private static final long ACTUAL_AT = offset("actual_emit_ns");
    private static final long TICK_AT = offset("encoder_tick");
    private static final long LENGTH_AT = offset("length_mm");
    private static final long WIDTH_AT = offset("width_mm");
    private static final long HEIGHT_AT = offset("height_mm");
    private static final long CONFIDENCE_AT = offset("scan_confidence_permille");
    private static final long BARCODE_AT = offset("barcode");

    private MemorySegment segment;
    private long base;

    /** Points the view at the record starting at {@code base}; returns this. */
    FlatParcel wrap(MemorySegment segment, long base) {
        this.segment = segment;
        this.base = base;
        return this;
    }

    int schemaId() {
        return Short.toUnsignedInt(segment.get(U16, base + SCHEMA_ID_AT));
    }

    int version() {
        return Short.toUnsignedInt(segment.get(U16, base + VERSION_AT));
    }

    long weightG() {
        return Integer.toUnsignedLong(segment.get(U32, base + WEIGHT_AT));
    }

    /** Unsigned 64-bit; use {@link Long#toUnsignedString(long)} to print it. */
    long seq() {
        return segment.get(U64, base + SEQ_AT);
    }

    long intendedEmitNs() {
        return segment.get(U64, base + INTENDED_AT);
    }

    long actualEmitNs() {
        return segment.get(U64, base + ACTUAL_AT);
    }

    long encoderTick() {
        return segment.get(U64, base + TICK_AT);
    }

    long lengthMm() {
        return Integer.toUnsignedLong(segment.get(U32, base + LENGTH_AT));
    }

    long widthMm() {
        return Integer.toUnsignedLong(segment.get(U32, base + WIDTH_AT));
    }

    long heightMm() {
        return Integer.toUnsignedLong(segment.get(U32, base + HEIGHT_AT));
    }

    long scanConfidencePermille() {
        return Integer.toUnsignedLong(segment.get(U32, base + CONFIDENCE_AT));
    }

    /** Allocates a String; the measured path reads the digits in place instead. */
    String barcode() {
        byte[] digits = new byte[BARCODE_LEN];
        MemorySegment.copy(segment, JAVA_BYTE, base + BARCODE_AT, digits, 0, BARCODE_LEN);
        return new String(digits, StandardCharsets.US_ASCII);
    }

    /** Writes a record: header constants, the fields given, zeroed reserved bytes. */
    static void write(MemorySegment segment, long base, long seq, long intendedEmitNs, long actualEmitNs,
            String barcode) {
        segment.asSlice(base, SIZE).fill((byte) 0);
        segment.set(U16, base + SCHEMA_ID_AT, (short) SCHEMA_ID);
        segment.set(U16, base + VERSION_AT, (short) VERSION);
        segment.set(U64, base + SEQ_AT, seq);
        segment.set(U64, base + INTENDED_AT, intendedEmitNs);
        segment.set(U64, base + ACTUAL_AT, actualEmitNs);
        byte[] digits = barcode.getBytes(StandardCharsets.US_ASCII);
        MemorySegment.copy(digits, 0, segment, JAVA_BYTE, base + BARCODE_AT, BARCODE_LEN);
    }

    /** Decodes a flat datagram into a reused {@link FlatParcel} view: no allocation per parcel. */
    static final class FlatDecoder implements Decoder<FlatParcel> {
        private final FlatParcel view = new FlatParcel();
        private ByteBuffer cachedBuffer;
        private MemorySegment cachedSegment;

        @Override
        public FlatParcel decode(ByteBuffer datagram) throws MalformedDatagramException {
            if (datagram.remaining() != SIZE) {
                throw new MalformedDatagramException("flat parcel-v1 is " + SIZE + " bytes, got " + datagram.remaining());
            }
            if (datagram != cachedBuffer) { // the receiver reuses one buffer: wrap it once
                cachedBuffer = datagram;
                cachedSegment = MemorySegment.ofBuffer(datagram.duplicate().clear());
            }
            view.wrap(cachedSegment, datagram.position());
            if (view.schemaId() != SCHEMA_ID || view.version() != VERSION) {
                throw new MalformedDatagramException("not parcel-v1: schema " + view.schemaId() + " version "
                        + view.version());
            }
            return view;
        }

        @Override
        public long seq(FlatParcel event) {
            return event.seq();
        }
    }
}
