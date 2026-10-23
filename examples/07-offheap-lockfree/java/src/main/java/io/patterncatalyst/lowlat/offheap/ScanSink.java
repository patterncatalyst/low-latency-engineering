package io.patterncatalyst.lowlat.offheap;

/** What runs on the decide thread: every hand-off structure drives one of these. */
public interface ScanSink {

    /** Called once on the decide thread before the first scan. */
    void onStart();

    /**
     * Called for each parcel in publication order. {@code pickupNs} is {@link System#nanoTime()}
     * read as soon as the decide thread had the parcel in hand; {@code pickupNs - scan.rxNs()}
     * is the hand-off latency. {@code scan} is valid only during the call.
     */
    void onScan(ScanView scan, long pickupNs);
}
