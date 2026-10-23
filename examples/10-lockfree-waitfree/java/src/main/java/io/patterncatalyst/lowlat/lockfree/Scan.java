package io.patterncatalyst.lowlat.lockfree;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;

/** One scan on its way from a camera's receive thread to the tracker. */
record Scan(int camera, long seq, long intendedNs, long encoderTick, String barcode, int confidencePermille) {

    /** The end-of-run marker: offered once, after every receive thread has finished. */
    static final Scan END = new Scan(-1, -1, 0, 0, "", 0);

    static Scan of(int camera, ParcelEvent event) {
        return new Scan(camera, event.getSeq(), event.getIntendedEmitNs(), event.getEncoderTick(), event.getBarcode(),
                event.getScanConfidencePermille());
    }
}
