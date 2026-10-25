package io.patterncatalyst.lowlat.ch15;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.util.BitSet;
import org.junit.jupiter.api.Test;

/** Unprivileged: a thread may always be pinned to a CPU it is already allowed to run on. */
class PlacementTest {

    // A real stat line shape: 52 fields, comm with a space and a parenthesis, processor (field 39) = 3.
    private static final String STAT = "4242 (C2 Compile(r)) S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 9 0 12345 1000000 500"
            + " 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0 0 0 0 0 0 0 0 0";

    @Test
    void lastCpuIsFieldThirtyNineEvenWhenTheNameHasSpacesAndParentheses() {
        assertEquals(3, TaskStat.lastCpu(STAT));
        assertEquals("C2 Compile(r)", TaskStat.comm(STAT));
    }

    @Test
    void aShortStatLineIsRejected() {
        assertThrows(IllegalArgumentException.class, () -> TaskStat.lastCpu("1 (x) S 1 2"));
    }

    @Test
    void everyJvmThreadHasALastRunCpuInsideTheOnlineRange() throws IOException {
        var sample = TaskStat.sampleSelf();
        assertFalse(sample.isEmpty());
        int online = Runtime.getRuntime().availableProcessors();
        assertTrue(sample.values().stream().allMatch(cpu -> cpu >= 0), sample.toString());
        assertTrue(online >= 1);
    }

    @Test
    void pinningToAnAllowedCpuIsKept() throws Exception {
        BitSet before = HotThread.allowed();
        int target = before.nextSetBit(0);
        assertTrue(target >= 0);
        // A fresh thread, so the test does not narrow the affinity of the JUnit worker.
        Throwable[] failure = new Throwable[1];
        Thread t = new Thread(() -> {
            try {
                HotThread.pinTo(target);
                assertEquals(target, HotThread.currentCpu());
                assertEquals(1, HotThread.allowed().cardinality());
            } catch (Throwable e) {
                failure[0] = e;
            }
        });
        t.start();
        t.join();
        if (failure[0] != null) {
            throw new AssertionError(failure[0]);
        }
    }
}
