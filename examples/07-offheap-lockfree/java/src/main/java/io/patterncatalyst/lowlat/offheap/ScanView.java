package io.patterncatalyst.lowlat.offheap;

/**
 * One scanned parcel as the decide thread sees it, whichever structure carried it across the
 * hand-off: an immutable {@link Scan} (the queues), a flyweight over the ring buffer's bytes
 * ({@link RingScan}) or a preallocated Disruptor {@link Slot}. The decide thread reads it only
 * during the call it is handed to; a view may be reused for the next parcel.
 */
public interface ScanView {

    /** {@code ParcelEvent.seq}. */
    long seq();

    /** {@code ParcelEvent.intended_emit_ns}: where the belt's schedule says the parcel was. */
    long intendedNs();

    /** {@link System#nanoTime()} on the receive thread just before the hand-off. */
    long rxNs();

    /** The 9-digit serial reference of the SSCC-18 (see {@link Barcode#serial}). */
    long serial();

    /** {@code ParcelEvent.encoder_tick}. */
    long encoderTick();

    int weightG();

    int lengthMm();

    int widthMm();

    int heightMm();

    int confidencePermille();
}
