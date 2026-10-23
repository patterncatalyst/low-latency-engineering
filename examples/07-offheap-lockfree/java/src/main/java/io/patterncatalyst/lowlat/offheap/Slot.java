package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;

/**
 * A Disruptor ring-buffer entry: allocated once when the ring is built and overwritten for every
 * parcel, so publishing allocates nothing. Fields are plain: the Disruptor's sequence publication
 * (a release store on the producer side, an acquire load on the consumer side) orders them.
 */
final class Slot implements ScanView {
    private long seq;
    private long intendedNs;
    private long rxNs;
    private long serial;
    private long encoderTick;
    private int weightG;
    private int lengthMm;
    private int widthMm;
    private int heightMm;
    private int confidencePermille;

    void fill(ParcelEvent event, long rxNs) {
        this.seq = event.getSeq();
        this.intendedNs = event.getIntendedEmitNs();
        this.rxNs = rxNs;
        this.serial = Barcode.serial(event.getBarcode());
        this.encoderTick = event.getEncoderTick();
        this.weightG = event.getWeightG();
        this.lengthMm = event.getDims().getLengthMm();
        this.widthMm = event.getDims().getWidthMm();
        this.heightMm = event.getDims().getHeightMm();
        this.confidencePermille = event.getScanConfidencePermille();
    }

    @Override
    public long seq() {
        return seq;
    }

    @Override
    public long intendedNs() {
        return intendedNs;
    }

    @Override
    public long rxNs() {
        return rxNs;
    }

    @Override
    public long serial() {
        return serial;
    }

    @Override
    public long encoderTick() {
        return encoderTick;
    }

    @Override
    public int weightG() {
        return weightG;
    }

    @Override
    public int lengthMm() {
        return lengthMm;
    }

    @Override
    public int widthMm() {
        return widthMm;
    }

    @Override
    public int heightMm() {
        return heightMm;
    }

    @Override
    public int confidencePermille() {
        return confidencePermille;
    }
}
