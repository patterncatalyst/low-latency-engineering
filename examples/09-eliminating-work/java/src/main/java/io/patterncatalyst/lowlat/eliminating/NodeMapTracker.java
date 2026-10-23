package io.patterncatalyst.lowlat.eliminating;

import java.util.HashMap;

/**
 * {@code HashMap<String, ParcelState>}: the idiomatic default. Every insert allocates a map node and a
 * {@link ParcelState}, every lookup chases table -> node -> key -> value, and the collector traces all of it.
 */
public final class NodeMapTracker implements Tracker {

    private final HashMap<String, ParcelState> map;

    public NodeMapTracker(int expected) {
        map = HashMap.newHashMap(expected); // sized so it never resizes: the allocation counted is per insert
    }

    @Override
    public Tracked track(Scan scan) {
        long sscc = Sscc.pack(scan.barcode);
        if (sscc == Sscc.INVALID) {
            return Tracked.REJECTED;
        }
        ParcelState existing = map.get(scan.barcode);
        if (existing != null) {
            existing.rescan(scan);
            return Tracked.UPDATED;
        }
        map.put(scan.barcode, ParcelState.of(scan, sscc));
        return Tracked.INSERTED;
    }

    @Override
    public boolean erase(String barcode) {
        return map.remove(barcode) != null;
    }

    @Override
    public byte findState(String barcode) {
        ParcelState p = map.get(barcode);
        return p == null ? ParcelState.EMPTY : p.state;
    }

    @Override
    public int sweepDue(long tick) {
        int due = 0;
        for (ParcelState p : map.values()) {
            if (p.state == ParcelState.IN_FLIGHT && p.dueTick <= tick) {
                due++;
            }
        }
        return due;
    }

    @Override
    public int expire(long tick) {
        int before = map.size();
        map.values().removeIf(p -> p.state == ParcelState.IN_FLIGHT && p.dueTick <= tick);
        return before - map.size();
    }

    @Override
    public int size() {
        return map.size();
    }
}
