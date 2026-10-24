package io.patterncatalyst.lowlat.ch12;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * The flat {@code parcel-v1} record (contracts/flat/parcel-v1): 80 bytes, little-endian. The receive
 * lane reads three fields at fixed offsets and does not copy the record.
 */
final class Wire {

    static final int SIZE = 80;
    private static final int SEQ = 8;
    private static final int INTENDED_EMIT_NS = 16;
    private static final int BARCODE = 56;
    private static final int BARCODE_LENGTH = 18;
    private static final int SERIAL_START = 8; // extension (1) + company prefix (7)
    private static final int SERIAL_END = 17; // the 9-digit serial; position 17 is the check digit
    static final int LANES = 8;
    private static final short SCHEMA_ID = 1;
    private static final short VERSION = 1;

    private Wire() {
    }

    /** A direct buffer in the wire's byte order, big enough for one record and a little more. */
    static ByteBuffer newBuffer() {
        return ByteBuffer.allocateDirect(128).order(ByteOrder.LITTLE_ENDIAN);
    }

    /** True when {@code buf} (position 0, limit = datagram length) is a version-1 record. */
    static boolean valid(ByteBuffer buf) {
        return buf.limit() == SIZE && buf.getShort(0) == SCHEMA_ID && buf.getShort(2) == VERSION;
    }

    static long seq(ByteBuffer buf) {
        return buf.getLong(SEQ);
    }

    static long intendedEmitNs(ByteBuffer buf) {
        return buf.getLong(INTENDED_EMIT_NS);
    }

    /**
     * The lane for the record's SSCC-18: the 9-digit serial modulo 8, as {@code Lanes.laneOf} in the
     * line consumer computes it, decoded in place from the bytes (no String).
     *
     * @throws IllegalArgumentException if the barcode is not 18 ASCII digits
     */
    static int lane(ByteBuffer buf) {
        long serial = 0;
        for (int i = 0; i < BARCODE_LENGTH; i++) {
            int digit = buf.get(BARCODE + i) - '0';
            if (digit < 0 || digit > 9) {
                throw new IllegalArgumentException("SSCC-18 must be digits only");
            }
            if (i >= SERIAL_START && i < SERIAL_END) {
                serial = serial * 10 + digit;
            }
        }
        return (int) (serial % LANES);
    }

    /** Writes a record (header, seq, intended emit time, barcode) into {@code out}, which it leaves ready to send. */
    static ByteBuffer encode(ByteBuffer out, long seq, long intendedEmitNs, String barcode) {
        out.clear();
        for (int i = 0; i < SIZE; i++) {
            out.put(i, (byte) 0);
        }
        out.putShort(0, SCHEMA_ID);
        out.putShort(2, VERSION);
        out.putLong(SEQ, seq);
        out.putLong(INTENDED_EMIT_NS, intendedEmitNs);
        for (int i = 0; i < BARCODE_LENGTH; i++) {
            out.put(BARCODE + i, (byte) barcode.charAt(i));
        }
        out.limit(SIZE);
        return out;
    }
}
