package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;

/**
 * The per-parcel hook of {@link LineReceiver}: what an example does with each parcel. The
 * receiver binds, parses, tracks sequence gaps and records; the handler supplies only its
 * handling and reports each parcel done through {@link Completion}, inside the call or later.
 *
 * <p>An {@link EventHandler} for the protobuf {@link ParcelEvent}; the event is parsed fresh
 * for each call and may be kept.
 */
@FunctionalInterface
public interface ParcelHandler extends EventHandler<ParcelEvent> {

    /**
     * Called once for each new parcel (in order, or after a gap) on the receive thread. Must
     * complete the parcel, now or later, via {@code done}.
     */
    @Override
    void onParcel(ParcelEvent event, Completion done);
}
