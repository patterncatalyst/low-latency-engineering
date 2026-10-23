package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;

/**
 * The hand-off from the receive thread to the decide thread: one producer, one consumer. This is
 * the <em>data</em> path. Divert commands never travel through it (see {@link CommandChannel}).
 */
public interface HandOff extends AutoCloseable {

    /**
     * Receive thread only. Hands one parcel over, with {@code rxNs} as its receive time.
     *
     * @return false when the structure is full; the parcel was not handed over (the belt does not
     *     wait, so there is no blocking variant)
     */
    boolean publish(ParcelEvent event, long rxNs);

    /** Starts the decide thread, which drives {@code sink} for each parcel in order. */
    void start(ScanSink sink, ThreadPlacement placement);

    /** The reason the decide thread died, or null while it is healthy. */
    Throwable failure();

    /** Stops the decide thread and joins it; the join publishes everything it wrote. */
    @Override
    void close();
}
