package io.patterncatalyst.lowlat.jvmcosts;

import io.patterncatalyst.lowlat.line.Completion;
import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.ParcelHandler;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.time.Instant;

/**
 * The handler of every Java run in this example: the tracker decides, the parcel is done, the lane is
 * counted. It also notes the wall-clock moment of the first parcel and of the first parcel past the
 * window, twice per run, so the JIT events of the recording can be assigned to a window afterwards.
 * The stamps are taken after the parcel is completed, outside its measured interval.
 */
final class TrackerHandler implements ParcelHandler {

    private final Tracker tracker = new Tracker();
    private final long window;
    private final long[] laneCounts = new long[Lanes.LANES];
    private Instant firstParcel;
    private Instant windowEnd;

    /** @param window parcels in the first window; 0 for none */
    TrackerHandler(long window) {
        this.window = window;
    }

    @Override
    public void onParcel(ParcelEvent event, Completion done) {
        DivertDecision decision = tracker.onParcel(event);
        laneCounts[decision.lane()]++;
        done.complete(event);
        if (firstParcel == null) {
            firstParcel = Instant.now();
        }
        if (window > 0 && windowEnd == null && event.getSeq() >= window) {
            windowEnd = Instant.now();
        }
    }

    long[] laneCounts() {
        return laneCounts.clone();
    }

    /** When the first parcel was handled, or null before one was. */
    Instant firstParcel() {
        return firstParcel;
    }

    /** When the first parcel past the window was handled, or null. */
    Instant windowEnd() {
        return windowEnd;
    }

    int inFlightCount() {
        return tracker.inFlightCount();
    }
}
