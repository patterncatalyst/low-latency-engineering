package io.patterncatalyst.lowlat.offheap;

import net.openhft.chronicle.core.values.LongValue;
import net.openhft.chronicle.map.ChronicleMap;
import net.openhft.chronicle.values.Values;

/**
 * The manifest as a Chronicle Map (open source, Apache-2.0): a hash map whose entries live in
 * native memory outside the Java heap, so the collector never traverses them. The heap holds the
 * map handle, not the million entries. A lookup serializes the key, probes native memory and
 * deserializes the value, so it costs more than a {@link java.util.HashMap} hit; what it buys is
 * a live set the collector does not have to carry.
 *
 * <p>The lookup follows Chronicle's zero-garbage route: the key is a reused {@link LongValue}
 * (a Chronicle Values instance, serialised in place, so no {@code Long} is boxed) and the value is
 * read into a reused {@link StringBuilder} with {@code getUsing}, so a hit creates no
 * {@code String}. Both are single-thread state: a manifest is looked up by the decide thread
 * only.
 *
 * <p>Only the in-process, non-replicated map is used; replication is a commercial feature.
 */
final class ChronicleMapManifest implements Manifest {

    static {
        ChronicleAnalytics.disable(); // before Chronicle builds its first map
    }

    private final ChronicleMap<LongValue, CharSequence> entries;
    private final LongValue key = Values.newHeapInstance(LongValue.class); // reused; decide thread only
    private final StringBuilder value = new StringBuilder(); // reused; decide thread only

    ChronicleMapManifest(int count) {
        this.entries = ChronicleMap.of(LongValue.class, CharSequence.class)
                .name("manifest")
                .entries(count)
                .averageValue(Manifest.destinationOf(0))
                .create();
        LongValue loadKey = Values.newHeapInstance(LongValue.class);
        for (long serial = 0; serial < count; serial++) {
            loadKey.setValue(serial);
            entries.put(loadKey, Manifest.destinationOf(serial));
        }
    }

    @Override
    public boolean contains(long serial) {
        key.setValue(serial);
        return entries.getUsing(key, value) != null;
    }

    @Override
    public String destination(long serial) {
        key.setValue(serial);
        CharSequence found = entries.getUsing(key, value);
        return found == null ? null : found.toString();
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
