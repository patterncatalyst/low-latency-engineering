package io.patterncatalyst.lowlat.flat;

import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import java.util.SplittableRandom;

/**
 * A batch of parcels laid out back to back in two direct buffers, one per wire format, so a
 * benchmark decodes the same parcels from the same kind of memory the receive loop uses. Each
 * datagram sits at {@code index * stride}; its length is in {@link #flatLength()} /
 * {@link #protobufLength(int)}.
 */
public final class SampleWire {

    /** Room for the largest protobuf-encoded ParcelEvent (about 90 bytes) rounded to a cache line multiple. */
    private static final int PROTOBUF_STRIDE = 128;

    private final int count;
    private final ByteBuffer flat;
    private final ByteBuffer protobuf;
    private final int[] protobufLengths;

    public SampleWire(int count, long seed) {
        if (count < 1) {
            throw new IllegalArgumentException("count must be at least 1");
        }
        this.count = count;
        this.flat = ByteBuffer.allocateDirect(count * ParcelLayout.SIZE);
        this.protobuf = ByteBuffer.allocateDirect(count * PROTOBUF_STRIDE);
        this.protobufLengths = new int[count];
        MemorySegment flatSegment = MemorySegment.ofBuffer(flat);
        SplittableRandom random = new SplittableRandom(seed);
        for (int i = 0; i < count; i++) {
            FlatRecord parcel = parcel(i, random);
            parcel.writeFlat(flatSegment, (long) i * ParcelLayout.SIZE);
            byte[] encoded = parcel.toProtobuf().toByteArray();
            protobuf.put(i * PROTOBUF_STRIDE, encoded);
            protobufLengths[i] = encoded.length;
        }
    }

    /** A parcel with line-like values: timestamps near a CLOCK_MONOTONIC reading, millimetre dimensions. */
    static FlatRecord parcel(long seq, SplittableRandom random) {
        StringBuilder barcode = new StringBuilder(ParcelLayout.BARCODE_LEN);
        for (int i = 0; i < ParcelLayout.BARCODE_LEN; i++) {
            barcode.append((char) ('0' + random.nextInt(10)));
        }
        long intended = 5_000_000_000_000L + seq * 100_000L; // 10 kHz
        return new FlatRecord(
                seq,
                intended,
                intended + random.nextInt(50_000),
                seq / 4, // 2.5 m/s x 1000 pulses per metre = 2,500 pulses/s; one parcel per 0.1 ms
                random.nextInt(100, 30_000),
                random.nextInt(100, 800),
                random.nextInt(100, 600),
                random.nextInt(50, 500),
                random.nextInt(300, 1000),
                barcode.toString());
    }

    public int count() {
        return count;
    }

    /** All flat datagrams, each {@link ParcelLayout#SIZE} bytes. The buffer is shared: callers set its position and limit. */
    public ByteBuffer flat() {
        return flat;
    }

    /** All protobuf datagrams, each at {@code index * 128} with {@link #protobufLength(int)} bytes. */
    public ByteBuffer protobuf() {
        return protobuf;
    }

    public int flatLength() {
        return ParcelLayout.SIZE;
    }

    public int protobufLength(int index) {
        return protobufLengths[index];
    }

    public int protobufStride() {
        return PROTOBUF_STRIDE;
    }
}
