package io.patterncatalyst.lowlat.flat;

import static java.lang.foreign.ValueLayout.JAVA_BYTE;

import java.lang.foreign.MemorySegment;
import java.nio.charset.StandardCharsets;
import java.util.Objects;

/**
 * A flyweight over one {@code parcel-v1} record: it holds the segment and the record's offset,
 * nothing else, and every getter reads the bytes where they are. {@link FlatDecoder} hands the
 * receive loop one instance and re-points it at each datagram, so decoding a parcel allocates
 * nothing. Treat a view as valid only until the next datagram: it does not own the bytes.
 *
 * <p>The record has unsigned fields. Getters return the next wider signed type for the 16 and
 * 32-bit ones; the 64-bit ones return the raw {@code long} (use {@link Long#toUnsignedString}
 * to print {@code seq} and {@code encoder_tick}).
 */
public final class FlatView {

    private static final int SERIAL_START = 8; // extension(1) + company prefix(7)
    private static final int SERIAL_END = 17; // 9-digit serial reference; digit 17 is the check digit
    private static final int LANES = 8;

    private MemorySegment segment;
    private long base;

    /** Points the view at the record that starts at {@code base}; returns this. */
    public FlatView wrap(MemorySegment segment, long base) {
        this.segment = segment;
        this.base = base;
        return this;
    }

    public int schemaId() {
        return Short.toUnsignedInt((short) ParcelLayout.SCHEMA_ID_H.get(segment, base));
    }

    public int version() {
        return Short.toUnsignedInt((short) ParcelLayout.VERSION_H.get(segment, base));
    }

    public long weightG() {
        return Integer.toUnsignedLong((int) ParcelLayout.WEIGHT_G.get(segment, base));
    }

    public long seq() {
        return (long) ParcelLayout.SEQ.get(segment, base);
    }

    public long intendedEmitNs() {
        return (long) ParcelLayout.INTENDED_EMIT_NS.get(segment, base);
    }

    public long actualEmitNs() {
        return (long) ParcelLayout.ACTUAL_EMIT_NS.get(segment, base);
    }

    public long encoderTick() {
        return (long) ParcelLayout.ENCODER_TICK.get(segment, base);
    }

    public long lengthMm() {
        return Integer.toUnsignedLong((int) ParcelLayout.LENGTH_MM.get(segment, base));
    }

    public long widthMm() {
        return Integer.toUnsignedLong((int) ParcelLayout.WIDTH_MM.get(segment, base));
    }

    public long heightMm() {
        return Integer.toUnsignedLong((int) ParcelLayout.HEIGHT_MM.get(segment, base));
    }

    public long scanConfidencePermille() {
        return Integer.toUnsignedLong((int) ParcelLayout.SCAN_CONFIDENCE_PERMILLE.get(segment, base));
    }

    /** One barcode byte (an ASCII digit), read in place. */
    public byte barcodeByte(int index) {
        return segment.get(JAVA_BYTE, base + ParcelLayout.BARCODE_AT + Objects.checkIndex(index, ParcelLayout.BARCODE_LEN));
    }

    /**
     * The sortation lane for this parcel: the 9-digit serial reference of the SSCC-18 modulo 8,
     * the same rule as {@code Lanes.laneOf(String)} but computed on the bytes, so no
     * {@code String} is created.
     *
     * @throws IllegalArgumentException if the barcode is not 18 ASCII digits
     */
    public int lane() {
        long serial = 0;
        for (int i = 0; i < ParcelLayout.BARCODE_LEN; i++) {
            int digit = barcodeByte(i) - '0';
            if (digit < 0 || digit > 9) {
                throw new IllegalArgumentException("SSCC-18 must be digits only, got '" + barcode() + "'");
            }
            if (i >= SERIAL_START && i < SERIAL_END) {
                serial = serial * 10 + digit;
            }
        }
        return (int) (serial % LANES);
    }

    /** The barcode as text. Allocates: tests and tools use it, the measured path does not. */
    public String barcode() {
        byte[] digits = new byte[ParcelLayout.BARCODE_LEN];
        MemorySegment.copy(segment, JAVA_BYTE, base + ParcelLayout.BARCODE_AT, digits, 0, ParcelLayout.BARCODE_LEN);
        return new String(digits, StandardCharsets.US_ASCII);
    }
}
