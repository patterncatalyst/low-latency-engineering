package io.patterncatalyst.lowlat.line;

/**
 * The per-parcel hook of {@link EventReceiver} for any decoded event type {@code E}. A
 * protobuf consumer uses {@link ParcelHandler}, which is this interface fixed to
 * {@code ParcelEvent}.
 *
 * <p>The receiver calls one handler instance for the whole run, so the call site is
 * monomorphic and the JIT inlines it: the hook adds no indirect call to the measured path.
 *
 * @param <E> the decoded event type (see {@link Decoder})
 */
public interface EventHandler<E> {

    /**
     * Called once for each new parcel (in order, or after a gap) on the receive thread. Must
     * complete the parcel, now or later, via {@code done}. {@code event} may be a view that the
     * decoder reuses: read what you need during the call.
     *
     * <p>Completion may move to another thread: see {@link Completion} for the ownership rule.
     */
    void onParcel(E event, Completion done);

    /**
     * Called once when the receive loop ends, on the receive thread, to complete the parcels the
     * handler still holds (a partial last batch) or to stop and join a thread that owns the
     * {@link Completion}. The default holds nothing.
     */
    default void drain(Completion done) {
    }
}
