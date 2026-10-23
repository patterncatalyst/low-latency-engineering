package io.patterncatalyst.lowlat.offheap;

import java.util.HashMap;
import java.util.Map;

/**
 * The manifest as a {@link HashMap} on the Java heap: the idiomatic choice. Every entry is a node,
 * a boxed key and a {@code String} with its backing array, and all of it lives in the old
 * generation for the whole shift. The collector has to mark it on every full cycle.
 */
final class OnHeapManifest implements Manifest {

    private final Map<Long, String> entries;

    OnHeapManifest(int count) {
        this.entries = HashMap.newHashMap(count);
        for (long serial = 0; serial < count; serial++) {
            entries.put(serial, Manifest.destinationOf(serial));
        }
    }

    @Override
    public String destination(long serial) {
        return entries.get(serial);
    }

    @Override
    public long size() {
        return entries.size();
    }

    @Override
    public void close() {
        entries.clear();
    }
}
