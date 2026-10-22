package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;

/**
 * The per-parcel hook of {@link LineReceiver}: what an example does with each parcel. The
 * receiver binds, parses, tracks sequence gaps and records; the handler supplies only its
 * handling and reports each parcel done through {@link Completion}, inside the call or later.
 *
 * <p>The receiver calls one handler instance for the whole run, so the call site is
 * monomorphic and the JIT inlines it: the hook adds no indirect call to the measured path.
 */
@FunctionalInterface
public interface ParcelHandler {

    /**
     * Called once for each new parcel (in order, or after a gap) on the receive thread. The
     * event is parsed fresh for each call and may be kept. Must complete the parcel, now or
     * later, via {@code done}.
     */
    void onParcel(ParcelEvent event, Completion done);

    /**
     * Called once when the run ends, to complete the parcels the handler still holds (a
     * partial last batch). The default holds nothing.
     */
    default void drain(Completion done) {
    }
}
