package io.patterncatalyst.lowlat.line;

import com.google.protobuf.InvalidProtocolBufferException;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.nio.ByteBuffer;

/**
 * Turns one datagram into the event type {@code E} the handler receives. The seam between the
 * wire and the handler: protobuf ({@link #protobuf()}) is the default, and a flat-record
 * decoder (Ch8) plugs in without touching the receive loop or the handlers' recording.
 *
 * <p>{@code E} is whatever the decoder wants the handler to see. A protobuf decoder returns a
 * fresh immutable {@link ParcelEvent}; a flat decoder can return a <em>view</em> over the
 * datagram bytes that is reused for every parcel, so decoding allocates nothing. A handler
 * therefore treats the event as valid only during {@code onParcel} unless the decoder's
 * documentation says otherwise.
 *
 * <p>The receiver holds one decoder for the whole run, so the call site is monomorphic and
 * inlines like the handler's.
 *
 * @param <E> the decoded event type
 */
public interface Decoder<E> {

    /**
     * Decodes the datagram between {@code datagram.position()} and {@code limit()}. The buffer
     * is the receiver's own direct buffer: do not keep it, and do not change its position or
     * limit.
     *
     * @throws MalformedDatagramException if the bytes are not a valid event; the receiver counts
     *     it and moves on
     */
    E decode(ByteBuffer datagram) throws MalformedDatagramException;

    /** The sequence number of a decoded event, for gap tracking. */
    long seq(E event);

    /** The default: a protobuf {@code lowlat.line.v1.ParcelEvent}, parsed in place from the direct buffer. */
    static Decoder<ParcelEvent> protobuf() {
        return ProtobufDecoder.INSTANCE;
    }

    /** The datagram is not a valid event for this decoder. */
    final class MalformedDatagramException extends Exception {
        private static final long serialVersionUID = 1L;

        public MalformedDatagramException(String message, Throwable cause) {
            super(message, cause);
        }

        public MalformedDatagramException(String message) {
            super(message);
        }
    }

    /** {@link #protobuf()}. */
    enum ProtobufDecoder implements Decoder<ParcelEvent> {
        INSTANCE;

        @Override
        public ParcelEvent decode(ByteBuffer datagram) throws MalformedDatagramException {
            try {
                // Direct, non-array buffer: protobuf-java reads it in place (no copy to byte[]).
                return ParcelEvent.parseFrom(datagram);
            } catch (InvalidProtocolBufferException e) {
                throw new MalformedDatagramException("not a ParcelEvent", e);
            }
        }

        @Override
        public long seq(ParcelEvent event) {
            return event.getSeq();
        }
    }
}
