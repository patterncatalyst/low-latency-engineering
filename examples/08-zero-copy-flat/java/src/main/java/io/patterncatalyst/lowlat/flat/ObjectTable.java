package io.patterncatalyst.lowlat.flat;

/** The pointer layout: an array of references to {@link ParcelState} objects scattered over the heap. */
public final class ObjectTable implements InFlightTable {

    private final ParcelState[] slots;

    public ObjectTable(ParcelState[] slots) {
        this.slots = slots;
    }

    @Override
    public int size() {
        return slots.length;
    }

    @Override
    public long sweepDue(long dueTick) {
        long weight = 0;
        for (ParcelState parcel : slots) {
            if (parcel.encoderTick() <= dueTick && parcel.state() == IN_FLIGHT) {
                weight += parcel.weightG();
            }
        }
        return weight;
    }
}
