package io.patterncatalyst.lowlat.eliminating;

/**
 * One scan of one parcel, as the tracker receives it. Mutable and reused by the caller: a flyweight is the
 * non-idiomatic choice (a record per scan is the idiomatic one), made here so the per-parcel path allocates
 * nothing and the allocation the chapter counts is the tracker's own.
 */
public final class Scan {
    /** 18 ASCII digits (SSCC-18). */
    public String barcode = "";
    public long seq;
    /** Encoder tick at the scanner. */
    public long tick;
    public int weightG;
    public short lengthMm;
    public short widthMm;
    public short heightMm;
    public short confidencePermille;

    /** Fills the scan for key number {@code i}; the same shape the C++ lane uses. */
    public Scan of(Keys keys, int i) {
        barcode = keys.text(i);
        seq = i;
        tick = i;
        weightG = 500 + i % 20_000;
        lengthMm = (short) (150 + i % 1000);
        widthMm = (short) (100 + i % 600);
        heightMm = (short) (50 + i % 450);
        confidencePermille = (short) (950 + i % 51);
        return this;
    }
}
