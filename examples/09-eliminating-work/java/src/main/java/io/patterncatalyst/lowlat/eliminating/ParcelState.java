package io.patterncatalyst.lowlat.eliminating;

/**
 * Everything the tracker knows about a parcel, in one object: the layout a first draft has. The sweep
 * reads {@code dueTick} and {@code state} and pulls the whole object (about 100 bytes with its header)
 * through the cache; each object is a separate heap allocation reached through an array of references.
 * Ch8's table held the same parcels in a {@code MemorySegment}; this one is the on-heap object model the
 * columns of {@link ColumnTable} are measured against.
 */
public final class ParcelState {
    // Byte codes, not an enum: they are the codes the byte[] state column of ColumnTable holds and the
    // one-byte field of the C++ lane's `enum class State : std::uint8_t`. An enum field would be a
    // reference, which changes the object layout that JOL and the sweep measure.
    public static final byte EMPTY = 0;
    public static final byte IN_FLIGHT = 1;
    public static final byte DIVERTED = 2;
    /** Encoder ticks from the scanner to the diverter: 1.2 m at 1000 pulses per metre. */
    public static final long DIVERT_TICKS = 1200;

    long sscc;
    long dueTick;
    long scanTick;
    long seq;
    long divertTick;
    int weightG;
    short lengthMm;
    short widthMm;
    short heightMm;
    short confidencePermille;
    byte state;
    byte lane;
    long destination0; // the sort-plan code, three words
    long destination1;
    long destination2;

    public static ParcelState of(Scan scan, long sscc) {
        ParcelState p = new ParcelState();
        p.sscc = sscc;
        p.dueTick = scan.tick + DIVERT_TICKS;
        p.scanTick = scan.tick;
        p.seq = scan.seq;
        p.weightG = scan.weightG;
        p.lengthMm = scan.lengthMm;
        p.widthMm = scan.widthMm;
        p.heightMm = scan.heightMm;
        p.confidencePermille = scan.confidencePermille;
        p.state = IN_FLIGHT;
        p.lane = (byte) (sscc % 8);
        return p;
    }

    /** What a re-scan changes: the reading and the due tick. */
    public void rescan(Scan scan) {
        dueTick = scan.tick + DIVERT_TICKS;
        scanTick = scan.tick;
        confidencePermille = scan.confidencePermille;
    }

    public byte state() {
        return state;
    }

    public long dueTick() {
        return dueTick;
    }

    public long sscc() {
        return sscc;
    }
}
