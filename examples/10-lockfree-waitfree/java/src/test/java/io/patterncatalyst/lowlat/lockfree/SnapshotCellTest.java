package io.patterncatalyst.lowlat.lockfree;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.util.Collections;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Deterministic checks of the read side: no reader ever returns a torn snapshot. */
class SnapshotCellTest {

    @ParameterizedTest
    @ValueSource(strings = {"rw-lock", "stamped-lock"})
    void readersNeverSeeATornSnapshot(String variant) throws Exception {
        SeqlockRun.Result result = SeqlockRun.run(SeqlockRun.cellFor(variant), 3, 300, 1000, Collections.nCopies(4, -1),
                new Placement.Gate(4, 0, false), LatencyRecorder.singleThreaded(ClaimRun.EXAMPLE, variant));
        assertEquals(0, result.torn());
        assertTrue(result.reads() > 0);
        assertTrue(result.updates() > 0);
    }

    @Test
    void aSnapshotWithMixedWordsFailsItsChecksum() {
        long[] a = new long[SnapshotCell.WORDS];
        long[] b = new long[SnapshotCell.WORDS];
        SnapshotCell.of(1, a);
        SnapshotCell.of(2, b);
        assertTrue(SnapshotCell.consistent(a));
        a[3] = b[3];
        assertFalse(SnapshotCell.consistent(a));
    }

    @Test
    void anIdleStampedCellReadsWithoutRetries() {
        SnapshotCell cell = new SnapshotCell.Stamped();
        long[] out = new long[SnapshotCell.WORDS];
        assertEquals(0, cell.read(out));
        assertTrue(SnapshotCell.consistent(out));
    }
}
