package io.patterncatalyst.lowlat.ch14;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class PeriodicWakeTest {

    @Test
    void remainingIsTheDistanceToTheDeadlineAndNeverNegative() {
        assertEquals(700, PeriodicWake.remaining(1_000, 300));
        assertEquals(0, PeriodicWake.remaining(1_000, 1_000));
        assertEquals(0, PeriodicWake.remaining(1_000, 5_000));
    }

    @Test
    void remainingSurvivesNanoTimeWrapAround() {
        long deadline = Long.MIN_VALUE + 100;  // nanoTime may wrap; only differences mean anything
        long now = Long.MAX_VALUE - 100;
        assertEquals(201, PeriodicWake.remaining(deadline, now));
    }

    @Test
    void nextDeadlineStepsFromTheDeadlineNotFromNow() {
        assertEquals(11_000, PeriodicWake.nextDeadline(10_000, 10_300, 1_000));
    }

    @Test
    void nextDeadlineSkipsWholePeriodsAfterAStall() {
        assertEquals(14_000, PeriodicWake.nextDeadline(10_000, 13_500, 1_000));
        assertEquals(12_000, PeriodicWake.nextDeadline(10_000, 11_000, 1_000));
    }

    @Test
    void rejectsANonPositivePeriod() {
        assertThrows(IllegalArgumentException.class, () -> new PeriodicWake(0));
    }

    @Test
    void aScriptedClockProducesTheExpectedLateness() {
        // Each wake-up reads the clock twice in the park loop's final check and once after it; the scripted clock
        // answers from a list, always at or past the deadline, so no real parking happens.
        long[] readings = {0, /* start */ 1_000, 1_000, /* wake 1 on time */ 2_250, 2_250, /* wake 2 250 late */ 3_000, 3_000};
        int[] at = {0};
        PeriodicWake wake = new PeriodicWake(1_000, () -> readings[Math.min(at[0]++, readings.length - 1)]);
        List<Long> late = new ArrayList<>();
        long skipped = wake.run(3, late::add);
        assertEquals(List.of(0L, 250L, 0L), late);
        assertEquals(0, skipped);
    }

    @Test
    void aRealRunWakesOnTimeAndNeverEarly() {
        PeriodicWake wake = new PeriodicWake(1_000_000);  // 1 ms
        List<Long> late = new ArrayList<>();
        long start = System.nanoTime();
        wake.run(20, late::add);
        long elapsed = System.nanoTime() - start;
        assertEquals(20, late.size());
        assertTrue(late.stream().allMatch(l -> l >= 0));
        assertTrue(elapsed >= 20_000_000L, "20 periods of 1 ms took " + elapsed + " ns");
    }
}
