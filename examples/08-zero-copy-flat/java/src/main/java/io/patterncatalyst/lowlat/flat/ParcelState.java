package io.patterncatalyst.lowlat.flat;

/**
 * What the in-flight tracker keeps for one parcel between the scanner and the diverter. This is the
 * pointer layout: a table of these is an array of references to separate heap objects. The flat
 * layout of the same fields is {@link FlatTable}.
 *
 * @param seq unsigned 64-bit parcel number
 * @param encoderTick belt position when the parcel was scanned
 * @param weightG grams
 * @param lane sortation lane, 0 to 7
 * @param state {@link InFlightTable#IN_FLIGHT} or {@link InFlightTable#DIVERTED}
 */
public record ParcelState(long seq, long encoderTick, int weightG, byte lane, byte state) {
}
