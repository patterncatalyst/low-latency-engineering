package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;

/**
 * The scan as an immutable value: what the {@code java.util.concurrent} queues carry. One
 * instance is allocated per parcel on the receive thread, which is the idiomatic JDK way and
 * the cost the ring-buffer variants avoid.
 */
record Scan(long seq, long intendedNs, long rxNs, long serial, long encoderTick, int weightG, int lengthMm,
        int widthMm, int heightMm, int confidencePermille) implements ScanView {

    static Scan of(ParcelEvent event, long rxNs) {
        return new Scan(event.getSeq(), event.getIntendedEmitNs(), rxNs, Barcode.serial(event.getBarcode()),
                event.getEncoderTick(), event.getWeightG(), event.getDims().getLengthMm(),
                event.getDims().getWidthMm(), event.getDims().getHeightMm(), event.getScanConfidencePermille());
    }
}
