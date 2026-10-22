package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import org.agrona.DirectBuffer;
import org.agrona.MutableDirectBuffer;

/**
 * The scan as bytes in the Agrona ring buffer's memory: {@link #write} on the receive thread,
 * a reusable flyweight on the decide thread. The layout is fixed and uses the buffer's native
 * byte order.
 */
final class RingScan implements ScanView {

    private static final int SEQ = 0;
    private static final int INTENDED = 8;
    private static final int RX = 16;
    private static final int SERIAL = 24;
    private static final int TICK = 32;
    private static final int WEIGHT = 40;
    private static final int LENGTH_MM = 44;
    private static final int WIDTH_MM = 46;
    private static final int HEIGHT_MM = 48;
    private static final int CONFIDENCE = 50;

    /** Payload bytes of one record (the ring adds its own 8-byte header). */
    static final int LENGTH = 56;

    private DirectBuffer buffer;
    private int offset;

    /** Writes the scan at {@code index} of {@code buffer}; {@code ring.tryClaim} returned the index. */
    static void write(MutableDirectBuffer buffer, int index, ParcelEvent event, long rxNs, long serial) {
        buffer.putLong(index + SEQ, event.getSeq());
        buffer.putLong(index + INTENDED, event.getIntendedEmitNs());
        buffer.putLong(index + RX, rxNs);
        buffer.putLong(index + SERIAL, serial);
        buffer.putLong(index + TICK, event.getEncoderTick());
        buffer.putInt(index + WEIGHT, event.getWeightG());
        buffer.putShort(index + LENGTH_MM, (short) event.getDims().getLengthMm());
        buffer.putShort(index + WIDTH_MM, (short) event.getDims().getWidthMm());
        buffer.putShort(index + HEIGHT_MM, (short) event.getDims().getHeightMm());
        buffer.putShort(index + CONFIDENCE, (short) event.getScanConfidencePermille());
    }

    RingScan wrap(DirectBuffer buffer, int offset) {
        this.buffer = buffer;
        this.offset = offset;
        return this;
    }

    @Override
    public long seq() {
        return buffer.getLong(offset + SEQ);
    }

    @Override
    public long intendedNs() {
        return buffer.getLong(offset + INTENDED);
    }

    @Override
    public long rxNs() {
        return buffer.getLong(offset + RX);
    }

    @Override
    public long serial() {
        return buffer.getLong(offset + SERIAL);
    }

    @Override
    public long encoderTick() {
        return buffer.getLong(offset + TICK);
    }

    @Override
    public int weightG() {
        return buffer.getInt(offset + WEIGHT);
    }

    @Override
    public int lengthMm() {
        return buffer.getShort(offset + LENGTH_MM) & 0xFFFF;
    }

    @Override
    public int widthMm() {
        return buffer.getShort(offset + WIDTH_MM) & 0xFFFF;
    }

    @Override
    public int heightMm() {
        return buffer.getShort(offset + HEIGHT_MM) & 0xFFFF;
    }

    @Override
    public int confidencePermille() {
        return buffer.getShort(offset + CONFIDENCE) & 0xFFFF;
    }
}
