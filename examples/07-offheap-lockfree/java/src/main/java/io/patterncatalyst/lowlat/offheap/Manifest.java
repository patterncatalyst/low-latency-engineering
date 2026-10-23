package io.patterncatalyst.lowlat.offheap;

/**
 * The shift manifest: the parcels the line expects, keyed by serial reference, each with its
 * destination. The decide thread looks a scanned parcel up in it; a parcel that is not on the
 * manifest goes to the exception lane.
 */
public interface Manifest extends AutoCloseable {

    /** The destination for {@code serial}, or null when the parcel is not on the manifest. */
    String destination(long serial);

    /**
     * Whether {@code serial} is on the manifest: the lookup the decide thread times. An
     * implementation may avoid materialising the destination, so this need not allocate.
     */
    default boolean contains(long serial) {
        return destination(serial) != null;
    }

    /** The manifest's entry count. */
    long size();

    @Override
    void close();

    /** The destination of the parcel with serial reference {@code serial}: the one source of the manifest's contents. */
    static String destinationOf(long serial) {
        return "DC%02d/DOCK%02d/LANE%d".formatted(serial % 40, serial % 24, serial % 8);
    }
}
