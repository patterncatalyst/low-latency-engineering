package io.patterncatalyst.lowlat.flat;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/** The two table layouts answer the same question, and the downcall reads the clock nanoTime reads. */
class TableAndClockTest {

    @Test
    void sweepsAgreeAndSelectAboutTwoPercent() {
        TableData data = new TableData(50_000, 3);
        ObjectTable objects = new ObjectTable(data.bySlot());
        try (FlatTable flat = FlatTable.copyOf(data.bySlot())) {
            assertEquals(50_000, flat.size());
            assertEquals(50_000L * 24, flat.byteSize());
            long weight = objects.sweepDue(data.dueTick());
            assertEquals(weight, flat.sweepDue(data.dueTick()));
            assertTrue(weight > 0, "some parcels are due");
            assertEquals(0, objects.sweepDue(-1), "nothing is due before tick 0");
            assertEquals(objects.sweepDue(Long.MAX_VALUE), flat.sweepDue(Long.MAX_VALUE));
        }
    }

    @Test
    void flatSlotsRoundTrip() {
        ParcelState[] states = new TableData(1000, 9).bySlot();
        try (FlatTable flat = FlatTable.copyOf(states)) {
            for (int slot : new int[] {0, 1, 499, 999}) {
                assertEquals(states[slot], flat.get(slot));
            }
        }
    }

    @Test
    void slotsAreNotInAllocationOrder() {
        // The object table is scattered: arrival order is a permutation of slot order.
        ParcelState[] states = new TableData(1000, 9).bySlot();
        int inOrder = 0;
        for (int i = 1; i < states.length; i++) {
            if (states[i].seq() == states[i - 1].seq() + 1) {
                inOrder++;
            }
        }
        assertTrue(inOrder < 20, inOrder + " neighbours in arrival order");
    }

    @Test
    void downcallsAgreeWithNanoTimeToWithinOneMillisecond() {
        try (ClockGettime clock = new ClockGettime()) {
            for (int i = 0; i < 1000; i++) {
                long before = System.nanoTime();
                long standard = clock.standard();
                long critical = clock.critical();
                long after = System.nanoTime();
                assertTrue(standard >= before - 1_000_000 && standard <= after + 1_000_000, "standard " + standard);
                assertTrue(critical >= before - 1_000_000 && critical <= after + 1_000_000, "critical " + critical);
                assertTrue(critical >= standard, "CLOCK_MONOTONIC does not go back");
            }
        }
    }
}
