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
    void nextDeadlineSkipsWholePeriodsAfterAStallButNotAGridPointEqualToNow() {
        assertEquals(14_000, PeriodicWake.nextDeadline(10_000, 13_500, 1_000));
        assertEquals(11_000, PeriodicWake.nextDeadline(10_000, 11_000, 1_000));  // now == next: not a miss
        assertEquals(13_000, PeriodicWake.nextDeadline(10_000, 13_000, 1_000));  // 11 and 12 skipped, 13 kept
    }

    @Test
    void missedInWindowCountsOnlyPeriodsInsideTheWindow() {
        assertEquals(3, PeriodicWake.missedInWindow(3, 11_000, 100_000, 1_000));
        assertEquals(3, PeriodicWake.missedInWindow(5, 11_000, 13_000, 1_000));
        assertEquals(0, PeriodicWake.missedInWindow(2, 20_000, 13_000, 1_000));
    }

    @Test
    void rejectsANonPositivePeriod() {
        assertThrows(IllegalArgumentException.class, () -> new PeriodicWake(0));
    }

    private static PeriodicWake scripted(long period, long... readings) {
        int[] at = {0};
        return new PeriodicWake(period, () -> readings[Math.min(at[0]++, readings.length - 1)]);
    }

    @Test
    void aScriptedClockProducesTheExpectedLateness() {
        // Per wake-up the clock is read once in the park loop's check (at or past the deadline, so nothing parks)
        // and once after it for the wake time; the first reading is the run's start.
        PeriodicWake wake = scripted(1_000, 0, /* start */ 1_000, 1_000, /* wake 1 on time */ 2_250, 2_250, /* wake 2 */ 3_000, 3_000);
        List<Long> late = new ArrayList<>();
        PeriodicWake.Result result = wake.run(3_000, late::add);
        assertEquals(List.of(0L, 250L, 0L), late);
        assertEquals(new PeriodicWake.Result(3, 0), result);
    }

    @Test
    void aStallEndsTheRunEarlyAndCountsTheMissedPeriods() {
        // Wake 1 on time at 1000; wake 2 comes at 4500, past the 3000 window: its deadline (2000) is recorded very late,
        // grid point 3000 is skipped, and the next deadline (5000) is beyond the window, so the run stops: 2 + 1 = 3 periods.
        PeriodicWake wake = scripted(1_000, 0, 1_000, 1_000, 4_500, 4_500);
        List<Long> late = new ArrayList<>();
        PeriodicWake.Result result = wake.run(3_000, late::add);
        assertEquals(List.of(0L, 2_500L), late);
        assertEquals(new PeriodicWake.Result(2, 1), result);
        assertEquals(3, result.samples() + result.missedPeriods());
    }

    @Test
    void aRealRunStaysInsideItsDurationAndAccountsForEveryPeriod() {
        PeriodicWake wake = new PeriodicWake(1_000_000);  // 1 ms
        List<Long> late = new ArrayList<>();
        long start = System.nanoTime();
        PeriodicWake.Result result = wake.run(20_000_000L, late::add);
        long elapsed = System.nanoTime() - start;
        assertEquals(result.samples(), late.size());
        assertEquals(20, result.samples() + result.missedPeriods());
        assertTrue(late.stream().allMatch(l -> l >= 0));
        assertTrue(elapsed < 220_000_000L, "20 ms run took " + elapsed + " ns");  // generous slack for a loaded runner
    }

    @Test
    void anInterruptedRunStopsInsteadOfSpinningAndKeepsTheFlag() {
        PeriodicWake wake = new PeriodicWake(1_000_000);
        Thread.currentThread().interrupt();
        try {
            PeriodicWake.Result result = wake.run(5_000_000_000L, l -> { });
            assertEquals(0, result.samples());
            assertTrue(Thread.currentThread().isInterrupted(), "the interrupt flag must stay set");
        } finally {
            Thread.interrupted();  // clear it so the next test on this worker thread is unaffected
        }
    }
}
