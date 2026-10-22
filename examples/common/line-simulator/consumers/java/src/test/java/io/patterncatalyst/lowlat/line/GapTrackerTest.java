package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class GapTrackerTest {

    @Test
    void forwardJumpsCountAsDropped() {
        GapTracker t = new GapTracker();
        for (long seq : new long[] {0, 1, 2, 5, 6}) {
            assertEquals(GapTracker.Arrival.NEW, t.observe(seq));
        }
        assertEquals(2, t.dropped());
        assertEquals(0, t.reordered());
        assertEquals(6, t.highest());
    }

    @Test
    void repeatedSeqIsReordered() {
        GapTracker t = new GapTracker();
        for (long seq : new long[] {0, 1, 2, 5, 6}) {
            t.observe(seq);
        }
        assertEquals(GapTracker.Arrival.REORDERED, t.observe(6));
        assertEquals(GapTracker.Arrival.REORDERED, t.observe(3));
        assertEquals(2, t.reordered());
        assertEquals(2, t.dropped());
    }

    @Test
    void lastGapReportsOnlyTheNewestJump() {
        GapTracker t = new GapTracker();
        t.observe(0);
        t.observe(4);
        assertEquals(3, t.lastGap());
        t.observe(5);
        assertEquals(0, t.lastGap());
    }

    @Test
    void firstSeqAboveZeroCountsTheMissingHead() {
        GapTracker t = new GapTracker();
        t.observe(3);
        assertEquals(3, t.dropped());
    }
}
