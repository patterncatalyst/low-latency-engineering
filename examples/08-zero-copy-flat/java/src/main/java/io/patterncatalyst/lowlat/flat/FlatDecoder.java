package io.patterncatalyst.lowlat.flat;

import io.patterncatalyst.lowlat.line.Decoder;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;

/**
 * Decodes {@code parcel-v1} datagrams for the receive loop: {@code Decoder<FlatView>}. There is
 * no parse. The receiver's direct buffer is wrapped once with {@link MemorySegment#ofBuffer},
 * and every datagram only re-points one {@link FlatView} at the bytes the kernel just wrote,
 * so the decoder allocates nothing per parcel and copies nothing.
 *
 * <p>Reading rules (contracts/flat/parcel-v1/README.md): the 4 header bytes are checked first,
 * {@code schema_id} then {@code version}, then the size for that version. A later, larger
 * version is therefore reported as unsupported, not as a bad size.
 *
 * <p>One instance serves one receive thread. The returned view is the same object every time
 * and is valid until the next call to {@link #decode}.
 */
public final class FlatDecoder implements Decoder<FlatView> {

    private static final int HEADER_BYTES = 4;

    private final FlatView view = new FlatView();
    private ByteBuffer wrapped;
    private MemorySegment segment;

    @Override
    public FlatView decode(ByteBuffer datagram) throws MalformedDatagramException {
        if (datagram.remaining() < HEADER_BYTES) {
            throw new MalformedDatagramException(
                    "parcel-v1 header is " + HEADER_BYTES + " bytes, got " + datagram.remaining());
        }
        // The receiver reuses one buffer, so the wrap (one allocation) happens once, not per parcel.
        if (datagram != wrapped) {
            // A segment over the whole buffer: ofBuffer would start at the current position, and
            // the view addresses the record by absolute offset.
            segment = MemorySegment.ofBuffer(datagram.duplicate().clear());
            wrapped = datagram;
        }
        long base = datagram.position();
        view.wrap(segment, base);
        if (view.schemaId() != ParcelLayout.SCHEMA_ID) {
            throw new MalformedDatagramException("not parcel-v1: schema_id " + view.schemaId());
        }
        if (view.version() != ParcelLayout.VERSION) {
            throw new MalformedDatagramException("unsupported parcel-v1 version " + view.version());
        }
        if (datagram.remaining() != ParcelLayout.SIZE) {
            throw new MalformedDatagramException(
                    "parcel-v1 is " + ParcelLayout.SIZE + " bytes, got " + datagram.remaining());
        }
        return view;
    }

    @Override
    public long seq(FlatView event) {
        return event.seq();
    }
}
