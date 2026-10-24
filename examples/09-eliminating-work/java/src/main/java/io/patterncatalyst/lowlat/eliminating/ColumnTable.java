package io.patterncatalyst.lowlat.eliminating;

/**
 * Struct of arrays: the sweep's two fields in their own primitive arrays (9 bytes per slot), the fields it never
 * reads in cold arrays. No object per parcel, so nothing for the collector to trace and nothing to chase.
 */
public final class ColumnTable implements RecordTable {

    // hot: read by the sweep
    private final long[] dueTick;
    private final byte[] state;
    // cold: read when the parcel is diverted or reported
    private final long[] sscc;
    private final long[] scanTick;
    private final long[] seq;
    private final int[] weightG;
    private final short[] confidencePermille;
    private final int[] free;
    private int freeCount;
    private int slots;

    public ColumnTable(int capacity) {
        dueTick = new long[capacity];
        state = new byte[capacity];
        sscc = new long[capacity];
        scanTick = new long[capacity];
        seq = new long[capacity];
        weightG = new int[capacity];
        confidencePermille = new short[capacity];
        free = new int[capacity];
    }

    @Override
    public int insert(Scan scan, long key) {
        int slot = freeCount > 0 ? free[--freeCount] : slots++;
        dueTick[slot] = scan.tick + ParcelState.DIVERT_TICKS;
        state[slot] = ParcelState.IN_FLIGHT;
        sscc[slot] = key;
        scanTick[slot] = scan.tick;
        seq[slot] = scan.seq;
        weightG[slot] = scan.weightG;
        confidencePermille[slot] = scan.confidencePermille;
        return slot;
    }

    @Override
    public void rescan(int slot, Scan scan) {
        dueTick[slot] = scan.tick + ParcelState.DIVERT_TICKS;
        scanTick[slot] = scan.tick;
        confidencePermille[slot] = scan.confidencePermille;
    }

    @Override
    public void erase(int slot) {
        state[slot] = ParcelState.EMPTY;
        free[freeCount++] = slot;
    }

    @Override
    public byte state(int slot) {
        return state[slot];
    }

    @Override
    public long key(int slot) {
        return sscc[slot];
    }

    @Override
    public long dueTick(int slot) {
        return dueTick[slot];
    }

    @Override
    public int slots() {
        return slots;
    }

    @Override
    public int sweepDue(long tick) {
        int due = 0;
        for (int i = 0; i < slots; i++) {
            if (state[i] == ParcelState.IN_FLIGHT && dueTick[i] <= tick) {
                due++;
            }
        }
        return due;
    }
}
