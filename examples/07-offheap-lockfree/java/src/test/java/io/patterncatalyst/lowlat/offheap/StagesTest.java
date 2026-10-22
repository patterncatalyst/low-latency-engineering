package io.patterncatalyst.lowlat.offheap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.v1.Lane;
import java.io.IOException;
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

    @Test
    void oldGenerationPoolNames() {
        assertTrue(OldGen.isOldGeneration("G1 Old Gen"));
        assertTrue(OldGen.isOldGeneration("Tenured Gen"));
        assertTrue(!OldGen.isOldGeneration("G1 Eden Space"));
        assertTrue(OldGen.usedAfterGc() > 0);
    }
}
