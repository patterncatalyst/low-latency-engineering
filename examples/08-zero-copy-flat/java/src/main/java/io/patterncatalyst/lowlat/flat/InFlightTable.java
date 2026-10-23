package io.patterncatalyst.lowlat.flat;

/**
 * The in-flight parcel table, one slot per parcel (a real tracker finds the slot from the barcode
 * with a hash; Ch8 measures the sweep that runs every encoder tick, which walks all slots).
 */
public interface InFlightTable {

    byte IN_FLIGHT = 1;
    byte DIVERTED = 2;

    int size();

    /**
     * The sweep run at each encoder tick: total weight in grams of the in-flight parcels whose
     * {@code encoderTick} has reached {@code dueTick}, that is, the parcels the diverter must
     * act on now. It reads three fields of every slot and nothing else.
     */
    long sweepDue(long dueTick);
}
