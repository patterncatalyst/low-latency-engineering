package io.patterncatalyst.lowlat.ch12;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class OpenLoopScheduleTest {

    @Test
    void sendTimesAreEvenlySpacedFromTheStart() {
        assertEquals(1_000L, OpenLoopSchedule.intendedSendNanos(1_000L, 0, 1_000));
        assertEquals(1_001_000L, OpenLoopSchedule.intendedSendNanos(1_000L, 1, 1_000));
        assertEquals(1_000_001_000L, OpenLoopSchedule.intendedSendNanos(1_000L, 1_000, 1_000));
    }
}
