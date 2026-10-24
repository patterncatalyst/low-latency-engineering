package io.patterncatalyst.lowlat.lockfree;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.time.Duration;
import java.util.Collections;
import java.util.concurrent.atomic.AtomicBoolean;
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

    /**
     * Negative control: the same eight words copied with no validation. If this reader never tore,
     * "zero torn reads" above would prove nothing. Loops until a tear is seen, bounded by a deadline.
     */
    @Test
    void negativeControlWithoutValidationReadsTornSnapshots() throws Exception {
        assumeTrue(Runtime.getRuntime().availableProcessors() >= 2, "a torn read needs the writer and the reader on different CPUs");
        long[] shared = new long[SnapshotCell.WORDS];
        SnapshotCell.of(0, shared);
        AtomicBoolean stop = new AtomicBoolean();
        Thread writer = new Thread(() -> {
            long[] next = new long[SnapshotCell.WORDS];
            for (long n = 1; !stop.get(); n++) {
                SnapshotCell.of(n, next);
                System.arraycopy(next, 0, shared, 0, SnapshotCell.WORDS);
            }
        });
        writer.setDaemon(true);
        writer.start();
        long torn = 0;
        long[] copy = new long[SnapshotCell.WORDS];
        long deadline = System.nanoTime() + Duration.ofSeconds(20).toNanos();
        try {
            while (torn == 0 && System.nanoTime() < deadline) {
                for (int i = 0; i < 100_000 && torn == 0; i++) {
                    System.arraycopy(shared, 0, copy, 0, SnapshotCell.WORDS);
                    if (!SnapshotCell.consistent(copy)) {
                        torn++;
                    }
                }
            }
        } finally {
            stop.set(true);
            writer.join();
        }
        assertTrue(torn > 0, "no torn read in 20 s: the checksum cannot detect tearing, so the zero above proves nothing");
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
