package io.patterncatalyst.lowlat.offheap;

import net.openhft.chronicle.map.ChronicleMap;

/**
 * The manifest as a Chronicle Map (open source, Apache-2.0): a hash map whose entries live in
 * native memory outside the Java heap, so the collector never traverses them. The heap holds the
 * map handle, not the million entries. A lookup serializes the key, probes native memory and
 * deserializes the value, so it costs more than a {@link java.util.HashMap} hit; what it buys is
 * a live set the collector does not have to carry.
 *
 * <p>Only the in-process, non-replicated map is used; replication is a commercial feature.
 */
final class ChronicleMapManifest implements Manifest {

    private final ChronicleMap<Long, String> entries;

    ChronicleMapManifest(int count) {
        this.entries = ChronicleMap.of(Long.class, String.class)
                .name("manifest")
                .entries(count)
                .averageValue(Manifest.destinationOf(0))
                .create();
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
        return entries.longSize();
    }

    @Override
    public void close() {
        entries.close();
    }
}
