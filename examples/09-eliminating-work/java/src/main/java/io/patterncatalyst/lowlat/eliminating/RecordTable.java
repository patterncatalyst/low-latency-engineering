package io.patterncatalyst.lowlat.eliminating;

/** The parcel records behind a tracker's index: slot -> state, and the per-tick due sweep over every slot. */
public interface RecordTable {

    /** Stores the parcel in a free slot and returns the slot. */
    int insert(Scan scan, long sscc);

    /** A re-scan: new due tick and reading, same slot. */
    void rescan(int slot, Scan scan);

    /** Frees the slot (its state becomes {@link ParcelState#EMPTY}) for reuse by a later insert. */
    void erase(int slot);

    byte state(int slot);

    long key(int slot);

    long dueTick(int slot);

    /** Slots in use or free, i.e. the high-water mark the sweep walks. */
    int slots();

    /** In-flight parcels due at {@code tick} or earlier. */
    int sweepDue(long tick);
}
