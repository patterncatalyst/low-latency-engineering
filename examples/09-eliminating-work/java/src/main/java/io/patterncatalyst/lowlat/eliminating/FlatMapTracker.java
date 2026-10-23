package io.patterncatalyst.lowlat.eliminating;

import org.agrona.collections.Long2LongHashMap;

/**
 * Agrona's {@link Long2LongHashMap} (open addressing over one {@code long[]} of key/value pairs) from the packed
 * SSCC to a slot, plus a {@link RecordTable}. Sized once at construction: an insert allocates nothing, a lookup
 * is one probe of the map and one read of a column.
 */
public final class FlatMapTracker implements Tracker {

    private static final long MISSING = -1L;

    private final Long2LongHashMap index;
    private final RecordTable table;

    public FlatMapTracker(int expected, RecordTable table) {
        // Agrona rounds the capacity up to a power of two (2^21 slots for 1.06 million parcels) and resizes at
        // capacity * loadFactor, which is above `expected` here, so `expected` entries never resize it. Passing
        // 2 * expected would only double the array to 2^22 slots (64 MB) and halve the load.
        this.index = new Long2LongHashMap(expected, 0.55f, MISSING);
        this.table = table;
    }

    /** The chapter's flat tracker: primitive map and hot/cold columns. */
    public static FlatMapTracker withColumns(int expected) {
        return new FlatMapTracker(expected, new ColumnTable(expected));
    }

    @Override
    public Tracked track(Scan scan) {
        long sscc = Sscc.pack(scan.barcode);
        if (sscc == Sscc.INVALID) {
            return Tracked.REJECTED;
        }
        long slot = index.get(sscc);
        if (slot == MISSING) {
            index.put(sscc, table.insert(scan, sscc));
            return Tracked.INSERTED;
        }
        table.rescan((int) slot, scan);
        return Tracked.UPDATED;
    }

    @Override
    public boolean erase(String barcode) {
        long sscc = Sscc.pack(barcode);
        return sscc != Sscc.INVALID && eraseKey(sscc);
    }

    /** Erases by packed key; the line already holds the barcode as text, the benchmarks may hold both. */
    public boolean eraseKey(long sscc) {
        long slot = index.remove(sscc);
        if (slot == MISSING) {
            return false;
        }
        table.erase((int) slot);
        return true;
    }

    @Override
    public byte findState(String barcode) {
        long sscc = Sscc.pack(barcode);
        return sscc == Sscc.INVALID ? ParcelState.EMPTY : findState(sscc);
    }

    /** State by packed key. */
    public byte findState(long sscc) {
        long slot = index.get(sscc);
        return slot == MISSING ? ParcelState.EMPTY : table.state((int) slot);
    }

    @Override
    public int sweepDue(long tick) {
        return table.sweepDue(tick);
    }

    @Override
    public int expire(long tick) {
        int erased = 0;
        for (int slot = 0; slot < table.slots(); slot++) {
            if (table.state(slot) == ParcelState.IN_FLIGHT && table.dueTick(slot) <= tick) {
                eraseKey(table.key(slot));
                erased++;
            }
        }
        return erased;
    }

    @Override
    public int size() {
        return index.size();
    }
}
