package io.patterncatalyst.lowlat.jvmcosts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.v1.Dimensions;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import org.junit.jupiter.api.Test;

class TrackerTest {

    private static ParcelEvent parcel(long seq, int weightG, int longestMm, int confidence) {
        return ParcelEvent.newBuilder()
                .setSeq(seq)
                .setEncoderTick(seq * 2)
                .setBarcode(SyntheticParcels.sscc(seq))
                .setWeightG(weightG)
                .setDims(Dimensions.newBuilder().setLengthMm(longestMm).setWidthMm(200).setHeightMm(100))
                .setScanConfidencePermille(confidence)
                .build();
    }

    @Test
    void laneFollowsConfidenceSizeAndWeight() {
        assertEquals(Tracker.EXCEPTION_LANE, Tracker.decide(parcel(0, 2500, 400, 800)).lane(), "unreadable scan");
        assertEquals(Tracker.OVERSIZE_LANE, Tracker.decide(parcel(0, 2500, 1200, 990)).lane(), "longer than 1 m");
        assertEquals(Tracker.OVERSIZE_LANE, Tracker.decide(parcel(0, 31_000, 400, 990)).lane(), "over 30 kg");
        assertEquals(1, Tracker.decide(parcel(0, 500, 400, 990)).lane(), "under 1 kg");
        assertEquals(3, Tracker.decide(parcel(0, 2500, 400, 990)).lane(), "2 kg class");
        assertEquals(Tracker.SORT_LANES, Tracker.decide(parcel(0, 20_000, 400, 990)).lane(), "heaviest sort lane");
    }

    @Test
    void deadlineIsTheScanTickPlusTheBeltDistance() {
        assertEquals(10 + Tracker.DIVERT_TICKS, Tracker.decide(parcel(5, 2500, 400, 990)).deadlineTick());
    }

    @Test
    void parcelsLeaveTheTableAtTheirDeadline() {
        Tracker tracker = new Tracker();
        // Two ticks apart: a parcel stays in flight while 600 successors arrive (1,200 ticks / 2).
        for (long seq = 0; seq < 2000; seq++) {
            tracker.onParcel(parcel(seq, 2500, 400, 990));
        }
        assertEquals(600, tracker.inFlightCount());
        assertTrue(tracker.isInFlight(SyntheticParcels.sscc(1999)));
        assertFalse(tracker.isInFlight(SyntheticParcels.sscc(0)));
    }

    @Test
    void theTableStaysBoundedWhenNoDeadlineEverPasses() {
        Tracker tracker = new Tracker();
        ParcelEvent frozenBelt = ParcelEvent.newBuilder(parcel(0, 2500, 400, 990)).setEncoderTick(0).build();
        for (long seq = 0; seq < 20_000; seq++) {
            tracker.onParcel(ParcelEvent.newBuilder(frozenBelt).setSeq(seq).setBarcode(SyntheticParcels.sscc(seq)).build());
        }
        assertEquals(8192, tracker.inFlightCount(), "the ring evicts the oldest instead of growing");
    }

    @Test
    void syntheticParcelsAreValidSsccs() {
        // GS1's worked example: 1 0614141 123456789, check digit 7.
        assertEquals(7, SyntheticParcels.checkDigit("10614141123456789"));
        for (ParcelEvent event : SyntheticParcels.batch(100, 1)) {
            assertEquals(18, event.getBarcode().length());
            Lanes.laneOf(event.getBarcode()); // throws on anything but 18 digits
        }
    }

    @Test
    void syntheticBatchesRepeatForASeed() {
        assertEquals(SyntheticParcels.batch(50, 7)[49], SyntheticParcels.batch(50, 7)[49]);
    }
}
