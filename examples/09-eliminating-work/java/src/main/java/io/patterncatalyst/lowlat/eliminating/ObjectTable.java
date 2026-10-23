package io.patterncatalyst.lowlat.eliminating;

/** Array of references to {@link ParcelState} objects: the sweep dereferences one object per slot. */
public final class ObjectTable implements RecordTable {

    private ParcelState[] rows;
    private int slots;
    private final int[] free;
    private int freeCount;

    public ObjectTable(int capacity) {
        rows = new ParcelState[capacity];
        free = new int[capacity]; // sized once: an insert never allocates the free list
    }

    /** A table over rows built elsewhere (the benchmark allocates them in shuffled order). */
    static ObjectTable adopt(ParcelState[] rows) {
        ObjectTable t = new ObjectTable(rows.length);
        t.rows = rows;
        t.slots = rows.length;
        return t;
    }

    @Override
    public int insert(Scan scan, long sscc) {
        ParcelState record = ParcelState.of(scan, sscc);
        if (freeCount > 0) {
            int slot = free[--freeCount];
            rows[slot] = record;
            return slot;
        }
        rows[slots] = record;
        return slots++;
    }

    @Override
    public void rescan(int slot, Scan scan) {
        rows[slot].rescan(scan);
    }

    @Override
    public void erase(int slot) {
        rows[slot] = null;
        free[freeCount++] = slot;
    }

    @Override
    public byte state(int slot) {
        ParcelState r = rows[slot];
        return r == null ? ParcelState.EMPTY : r.state;
    }

    @Override
    public long key(int slot) {
        return rows[slot].sscc;
    }

    @Override
    public long dueTick(int slot) {
        return rows[slot].dueTick;
    }

    @Override
    public int slots() {
        return slots;
    }

    @Override
    public int sweepDue(long tick) {
        int due = 0;
        for (int i = 0; i < slots; i++) {
            ParcelState r = rows[i];
            if (r != null && r.state == ParcelState.IN_FLIGHT && r.dueTick <= tick) {
                due++;
            }
        }
        return due;
    }
}
