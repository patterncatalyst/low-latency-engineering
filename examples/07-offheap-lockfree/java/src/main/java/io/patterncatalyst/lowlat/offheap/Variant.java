package io.patterncatalyst.lowlat.offheap;

import com.lmax.disruptor.BlockingWaitStrategy;
import com.lmax.disruptor.BusySpinWaitStrategy;
import java.io.IOException;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.stream.Collectors;
import org.agrona.concurrent.BackoffIdleStrategy;
import org.agrona.concurrent.BusySpinIdleStrategy;

/**
 * The ten variants. Each one changes a single stage of the pipeline and holds the others at a
 * fixed baseline (a busy-spin Agrona ring, no journal, no manifest), so a difference between two
 * variants belongs to the stage they differ in. {@code --journal} and {@code --manifest} compose
 * the stages for a full run.
 */
public enum Variant {
    BLOCKING_QUEUE("blocking-queue", HandOffKind.BLOCKING_QUEUE, JournalKind.NONE, ManifestKind.NONE),
    LINKED_QUEUE("linked-queue", HandOffKind.LINKED_QUEUE, JournalKind.NONE, ManifestKind.NONE),
    AGRONA_SPSC("agrona-spsc", HandOffKind.AGRONA_BUSY_SPIN, JournalKind.NONE, ManifestKind.NONE),
    AGRONA_SPSC_BACKOFF("agrona-spsc-backoff", HandOffKind.AGRONA_BACKOFF, JournalKind.NONE, ManifestKind.NONE),
    DISRUPTOR("disruptor", HandOffKind.DISRUPTOR_BUSY_SPIN, JournalKind.NONE, ManifestKind.NONE),
    DISRUPTOR_BLOCKING_WAIT("disruptor-blocking-wait", HandOffKind.DISRUPTOR_BLOCKING, JournalKind.NONE,
            ManifestKind.NONE),
    CHRONICLE_JOURNAL("chronicle-journal", HandOffKind.AGRONA_BUSY_SPIN, JournalKind.CHRONICLE, ManifestKind.NONE),
    WRITE_PER_PARCEL("write-per-parcel", HandOffKind.AGRONA_BUSY_SPIN, JournalKind.FILE, ManifestKind.NONE),
    CHRONICLE_MAP_MANIFEST("chronicle-map-manifest", HandOffKind.AGRONA_BUSY_SPIN, JournalKind.NONE,
            ManifestKind.CHRONICLE_MAP),
    ON_HEAP_MANIFEST("on-heap-manifest", HandOffKind.AGRONA_BUSY_SPIN, JournalKind.NONE, ManifestKind.ON_HEAP);

    private final String label;
    private final HandOffKind handOff;
    private final JournalKind journal;
    private final ManifestKind manifest;

    Variant(String label, HandOffKind handOff, JournalKind journal, ManifestKind manifest) {
        this.label = label;
        this.handOff = handOff;
        this.journal = journal;
        this.manifest = manifest;
    }

    /** The name used on the command line and in the reports. */
    public String label() {
        return label;
    }

    public HandOffKind handOff() {
        return handOff;
    }

    public JournalKind journal() {
        return journal;
    }

    public ManifestKind manifest() {
        return manifest;
    }

    public static Variant of(String label) {
        return Arrays.stream(values()).filter(v -> v.label.equals(label)).findFirst()
                .orElseThrow(() -> new IllegalArgumentException("--variant: "
                        + Arrays.stream(values()).map(Variant::label).collect(Collectors.joining(" | "))));
    }

    /** Which structure carries the parcel from the receive thread to the decide thread. */
    public enum HandOffKind {
        BLOCKING_QUEUE, LINKED_QUEUE, AGRONA_BUSY_SPIN, AGRONA_BACKOFF, DISRUPTOR_BUSY_SPIN, DISRUPTOR_BLOCKING;

        HandOff create(int slots) {
            return switch (this) {
                case BLOCKING_QUEUE -> QueueHandOff.arrayBacked(slots);
                case LINKED_QUEUE -> QueueHandOff.linkedBacked(slots);
                case AGRONA_BUSY_SPIN -> new RingHandOff(slots, BusySpinIdleStrategy::new);
                case AGRONA_BACKOFF -> new RingHandOff(slots, BackoffIdleStrategy::new);
                case DISRUPTOR_BUSY_SPIN -> new DisruptorHandOff(slots, new BusySpinWaitStrategy());
                case DISRUPTOR_BLOCKING -> new DisruptorHandOff(slots, new BlockingWaitStrategy());
            };
        }
    }

    /** Where the audit record goes. */
    public enum JournalKind {
        NONE, CHRONICLE, FILE;

        /** The journal under {@code directory}, or null for {@link #NONE}. */
        Journal open(Path directory) throws IOException {
            return switch (this) {
                case NONE -> null;
                case CHRONICLE -> new ChronicleJournal(directory.resolve("chronicle"));
                case FILE -> new FileJournal(directory.resolve("audit.bin"));
            };
        }

        static JournalKind of(String name) {
            return switch (name) {
                case "none" -> NONE;
                case "chronicle" -> CHRONICLE;
                case "file" -> FILE;
                default -> throw new IllegalArgumentException("--journal: none | chronicle | file");
            };
        }
    }

    /** Where the shift manifest lives. */
    public enum ManifestKind {
        NONE, ON_HEAP, CHRONICLE_MAP;

        /** A manifest of {@code entries} parcels, or null for {@link #NONE}. */
        Manifest open(int entries) {
            return switch (this) {
                case NONE -> null;
                case ON_HEAP -> new OnHeapManifest(entries);
                case CHRONICLE_MAP -> new ChronicleMapManifest(entries);
            };
        }

        static ManifestKind of(String name) {
            return switch (name) {
                case "none" -> NONE;
                case "on-heap" -> ON_HEAP;
                case "chronicle-map" -> CHRONICLE_MAP;
                default -> throw new IllegalArgumentException("--manifest: none | on-heap | chronicle-map");
            };
        }
    }
}
