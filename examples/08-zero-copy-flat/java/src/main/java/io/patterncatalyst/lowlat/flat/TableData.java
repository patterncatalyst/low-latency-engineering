package io.patterncatalyst.lowlat.flat;

import java.util.SplittableRandom;

/**
 * Deterministic in-flight parcels for the table benchmarks. Parcels are created in arrival order
 * but stored at the slot a hash would pick, so slot order is not allocation order: walking the
 * slots walks the heap in a scattered order, as a tracker that has been running for a while does.
 */
public final class TableData {

    /** About 2 percent of the slots are due at the sweep's tick: the few parcels at the diverter. */
    private static final double DUE_FRACTION = 0.02;

    private final ParcelState[] bySlot;
    private final long dueTick;

    public TableData(int size, long seed) {
        SplittableRandom random = new SplittableRandom(seed);
        int[] slotOf = new int[size];
        for (int i = 0; i < size; i++) {
            slotOf[i] = i;
        }
        for (int i = size - 1; i > 0; i--) { // Fisher-Yates
            int j = random.nextInt(i + 1);
            int swap = slotOf[i];
            slotOf[i] = slotOf[j];
            slotOf[j] = swap;
        }
        bySlot = new ParcelState[size];
        for (int arrival = 0; arrival < size; arrival++) {
            bySlot[slotOf[arrival]] = new ParcelState(
                    arrival,
                    arrival / 4, // 2,500 pulses/s at 10 kHz
                    random.nextInt(100, 30_000),
                    (byte) random.nextInt(8),
                    random.nextInt(10) == 0 ? InFlightTable.DIVERTED : InFlightTable.IN_FLIGHT);
        }
        dueTick = (long) (size * DUE_FRACTION) / 4;
    }

    /** The parcels in slot order. */
    public ParcelState[] bySlot() {
        return bySlot;
    }

    /** The tick of the sweep. */
    public long dueTick() {
        return dueTick;
    }
}
