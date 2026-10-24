package io.patterncatalyst.lowlat.eliminating;

/**
 * The in-flight parcel tracker, barcode to parcel state: {@link NodeMapTracker} (the JDK default) and
 * {@link FlatMapTracker} (a primitive open-addressing map to slots).
 */
public interface Tracker {

    enum Tracked { INSERTED, UPDATED, REJECTED }

    /** Inserts the parcel, or re-scans it when the barcode is already tracked. */
    Tracked track(Scan scan);

    /** Stops tracking the parcel; false when it was not tracked. */
    boolean erase(String barcode);

    /** The parcel's state, {@link ParcelState#EMPTY} when it is not tracked. */
    byte findState(String barcode);

    /** In-flight parcels due at {@code tick} or earlier (read-only). */
    int sweepDue(long tick);

    /** Erases the parcels due at {@code tick} or earlier and returns how many. */
    int expire(long tick);

    int size();
}
