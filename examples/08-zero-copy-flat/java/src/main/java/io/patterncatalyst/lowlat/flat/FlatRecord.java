package io.patterncatalyst.lowlat.flat;

import static java.lang.foreign.ValueLayout.JAVA_BYTE;

import io.patterncatalyst.lowlat.line.v1.Dimensions;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.lang.foreign.MemorySegment;
import java.nio.charset.StandardCharsets;

/**
 * One parcel as plain values: the input of the two writers (flat record and protobuf message) that
 * give the benchmarks identical parcels in both wire formats. The C++ simulator is the real
 * producer; this is for tests and benchmarks, where Java needs bytes of its own.
 *
 * @param seq unsigned 64-bit
 * @param encoderTick unsigned 64-bit
 * @param weightG unsigned 32-bit
 * @param lengthMm unsigned 32-bit
 * @param widthMm unsigned 32-bit
 * @param heightMm unsigned 32-bit
 * @param scanConfidencePermille unsigned 32-bit
 * @param barcode SSCC-18, 18 ASCII digits
 */
public record FlatRecord(
        long seq,
        long intendedEmitNs,
        long actualEmitNs,
        long encoderTick,
        int weightG,
        int lengthMm,
        int widthMm,
        int heightMm,
        int scanConfidencePermille,
        String barcode) {

    public FlatRecord {
        if (barcode.length() != ParcelLayout.BARCODE_LEN) {
            throw new IllegalArgumentException("SSCC-18 must be 18 digits, got '" + barcode + "'");
        }
    }

    /** Writes the 80-byte record at {@code base}: header constants, the fields, zeroed reserved bytes. */
    public void writeFlat(MemorySegment segment, long base) {
        segment.asSlice(base, ParcelLayout.SIZE).fill((byte) 0);
        ParcelLayout.SCHEMA_ID_H.set(segment, base, (short) ParcelLayout.SCHEMA_ID);
        ParcelLayout.VERSION_H.set(segment, base, (short) ParcelLayout.VERSION);
        ParcelLayout.WEIGHT_G.set(segment, base, weightG);
        ParcelLayout.SEQ.set(segment, base, seq);
        ParcelLayout.INTENDED_EMIT_NS.set(segment, base, intendedEmitNs);
        ParcelLayout.ACTUAL_EMIT_NS.set(segment, base, actualEmitNs);
        ParcelLayout.ENCODER_TICK.set(segment, base, encoderTick);
        ParcelLayout.LENGTH_MM.set(segment, base, lengthMm);
        ParcelLayout.WIDTH_MM.set(segment, base, widthMm);
        ParcelLayout.HEIGHT_MM.set(segment, base, heightMm);
        ParcelLayout.SCAN_CONFIDENCE_PERMILLE.set(segment, base, scanConfidencePermille);
        byte[] digits = barcode.getBytes(StandardCharsets.US_ASCII);
        MemorySegment.copy(digits, 0, segment, JAVA_BYTE, base + ParcelLayout.BARCODE_AT, ParcelLayout.BARCODE_LEN);
    }

    /** The same parcel as the protobuf message of {@code contracts/proto}. */
    public ParcelEvent toProtobuf() {
        return ParcelEvent.newBuilder()
                .setSeq(seq)
                .setIntendedEmitNs(intendedEmitNs)
                .setActualEmitNs(actualEmitNs)
                .setEncoderTick(encoderTick)
                .setBarcode(barcode)
                .setWeightG(weightG)
                .setDims(Dimensions.newBuilder()
                        .setLengthMm(lengthMm)
                        .setWidthMm(widthMm)
                        .setHeightMm(heightMm))
                .setScanConfidencePermille(scanConfidencePermille)
                .build();
    }
}
