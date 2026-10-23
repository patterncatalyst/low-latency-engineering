package io.patterncatalyst.lowlat.offheap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.v1.Lane;
import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

/** The lane rule, the journals and the manifests, each on its own. */
class StagesTest {

    @Test
    void laneRuleMatchesTheCommonLaneLookup() {
        for (long seq = 0; seq < 200; seq++) {
            String barcode = "00614141%09d".formatted(seq) + "0";
            Scan scan = Scan.of(HandOffTest.parcel(seq), 0);
            Lane lane = DecideStage.laneFor(scan, true);
            assertEquals(Lane.LANE_1_VALUE + Lanes.laneOf(barcode), lane.getNumber(), "seq " + seq);
        }
    }

    @Test
    void doubtfulReadsAndUnmanifestedParcelsGoToTheExceptionLane() {
        Scan sure = Scan.of(HandOffTest.parcel(3), 0);
        assertEquals(Lane.LANE_EXCEPTION, DecideStage.laneFor(sure, false));
        Scan doubtful = new Scan(3, 0, 0, 3, 0, 1_000, 100, 100, 100, DecideStage.MIN_CONFIDENCE_PERMILLE - 1);
        assertEquals(Lane.LANE_EXCEPTION, DecideStage.laneFor(doubtful, true));
    }

    @ParameterizedTest
    @EnumSource(value = Variant.JournalKind.class, names = {"CHRONICLE", "FILE"})
    void journalReadsBackEveryRecordInOrder(Variant.JournalKind kind, @TempDir Path dir) throws IOException {
        int n = 1_000;
        try (Journal journal = kind.open(dir)) {
            journal.bindToDecideThread();
            for (long seq = 0; seq < n; seq++) {
                journal.append(Scan.of(HandOffTest.parcel(seq), 0), 99, 2);
            }
            assertEquals(new Journal.Readback(n, true), journal.readBack());
        }
    }

    @Test
    void noJournalAndNoManifestAreNull(@TempDir Path dir) throws IOException {
        assertNull(Variant.JournalKind.NONE.open(dir));
        assertNull(Variant.ManifestKind.NONE.open(10));
    }

    @ParameterizedTest
    @EnumSource(value = Variant.ManifestKind.class, names = {"ON_HEAP", "CHRONICLE_MAP"})
    void manifestsHoldTheSameEntries(Variant.ManifestKind kind) {
        try (Manifest manifest = kind.open(2_000)) {
            assertEquals(2_000, manifest.size());
            for (long serial : new long[] {0, 1, 777, 1_999}) {
                assertEquals(Manifest.destinationOf(serial), manifest.destination(serial));
            }
            assertNull(manifest.destination(2_000));
            assertTrue(manifest.destination(5).startsWith("DC05/"));
        }
    }

    @ParameterizedTest
    @EnumSource(value = Variant.ManifestKind.class, names = {"ON_HEAP", "CHRONICLE_MAP"})
    void containsAgreesWithDestination(Variant.ManifestKind kind) {
        try (Manifest manifest = kind.open(500)) {
            for (long serial : new long[] {0, 1, 250, 499, 500, 501, 100_000, -1}) {
                assertEquals(manifest.destination(serial) != null, manifest.contains(serial), "serial " + serial);
            }
            assertTrue(manifest.contains(0));
            assertTrue(manifest.contains(499));
            assertFalse(manifest.contains(500));
            assertFalse(manifest.contains(-1));
        }
    }

    /** The Chronicle Map lookup reuses its key and value, so a steady run of hits allocates (almost) nothing. */
    @Test
    void chronicleMapLookupDoesNotAllocatePerHit() {
        int lookups = 200_000;
        try (Manifest manifest = Variant.ManifestKind.CHRONICLE_MAP.open(1_000)) {
            for (int i = 0; i < lookups; i++) {
                manifest.contains(i % 1_000); // warm up: class loading, JIT, the reused buffers
            }
            var threads = (com.sun.management.ThreadMXBean) ManagementFactory.getThreadMXBean();
            long before = threads.getCurrentThreadAllocatedBytes();
            int hits = 0;
            for (int i = 0; i < lookups; i++) {
                if (manifest.contains(i % 1_000)) {
                    hits++;
                }
            }
            long bytes = threads.getCurrentThreadAllocatedBytes() - before;
            assertEquals(lookups, hits);
            assertTrue(bytes / lookups < 16, bytes + " bytes over " + lookups + " lookups");
        }
    }

    @Test
    void oldGenerationPoolNames() {
        assertTrue(OldGen.isOldGeneration("G1 Old Gen"));
        assertTrue(OldGen.isOldGeneration("Tenured Gen"));
        assertFalse(OldGen.isOldGeneration("G1 Eden Space"));
        assertTrue(OldGen.usedAfterGc() > 0);
    }
}
