package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import com.google.protobuf.InvalidProtocolBufferException;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.net.StandardProtocolFamily;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.util.Arrays;

/**
 * Receives {@link ParcelEvent} datagrams and records {@code done_ns - intended_emit_ns}.
 * The constructor binds; {@link #run()} is the single receive thread; {@link #stop()} may be
 * called from any thread. Everything else is owned by the receive thread, and readers must
 * happen-after {@code run()} returns (join the thread).
 */
public final class LineReceiver implements AutoCloseable {

    /** Why {@link #run()} returned. */
    public enum StopReason { EXPECTED, IDLE, REQUESTED }

    /** A negative latency means the producer and this JVM are not on one monotonic clock. */
    public static final class NegativeLatencyException extends IllegalStateException {
        private static final long serialVersionUID = 1L;

        NegativeLatencyException(String message) {
            super(message);
        }
    }

    private static final int MAX_DATAGRAM = 64 * 1024;

    private final Config config;
    private final DatagramChannel channel;
    private final Selector selector;
    private final int grantedRcvbuf;
    private final ByteBuffer buffer = ByteBuffer.allocateDirect(MAX_DATAGRAM);
    private final LatencyRecorder recorder;
    private final GapTracker gaps = new GapTracker();
    private final Completion completion;
    private final long[] laneCounts = new long[Lanes.LANES];
    private long received;
    private long malformed;
    private volatile boolean stopRequested;

    public LineReceiver(Config config) throws IOException {
        this.config = config;
        this.recorder = LatencyRecorder.singleThreaded(config.example(), config.variant());
        this.completion = new Completion(recorder);
        DatagramChannel ch = DatagramChannel.open(StandardProtocolFamily.INET);
        try {
            ch.setOption(StandardSocketOptions.SO_RCVBUF, config.rcvbuf());
            ch.bind(config.bindAddress());
            ch.configureBlocking(false);
            this.selector = Selector.open();
            ch.register(selector, SelectionKey.OP_READ);
        } catch (IOException | RuntimeException e) {
            ch.close();
            throw e;
        }
        this.channel = ch;
        this.grantedRcvbuf = ch.getOption(StandardSocketOptions.SO_RCVBUF);
    }

    public int grantedRcvbuf() {
        return grantedRcvbuf;
    }

    public InetSocketAddress localAddress() throws IOException {
        return (InetSocketAddress) channel.getLocalAddress();
    }

    public LatencyRecorder recorder() {
        return recorder;
    }

    /** Parcels newly counted missing from the sequence so far. */
    public long dropped() {
        return gaps.dropped();
    }

    /** Datagrams at or below the highest seq seen (reordered or duplicated). */
    public long reordered() {
        return gaps.reordered();
    }

    /** What the handlers completed so far; read it after {@code run} returns. */
    public Completion completion() {
        return completion;
    }

    GapTracker gaps() {
        return gaps;
    }

    public long received() {
        return received;
    }

    public long malformed() {
        return malformed;
    }

    public long[] laneCounts() {
        return laneCounts.clone();
    }

    public void stop() {
        stopRequested = true;
        selector.wakeup();
    }

    /** Receives with the example 00 handler: the lane lookup, then done. Fills {@link #laneCounts()}. */
    public StopReason run() throws IOException {
        return run((event, done) -> {
            laneCounts[Lanes.laneOf(event.getBarcode())]++; // the r01 "handle" step
            done.complete(event);
        });
    }

    /**
     * Receives until the expected count, the idle timeout or {@link #stop()}, calling
     * {@code handler} for each new parcel and then {@link ParcelHandler#drain}. Gaps are booked
     * into the recorder as they appear.
     */
    public StopReason run(ParcelHandler handler) throws IOException {
        StopReason reason = receive(handler);
        handler.drain(completion);
        return reason;
    }

    private StopReason receive(ParcelHandler handler) throws IOException {
        long lastRxNs = 0;
        boolean seenFirst = false;
        while (!stopRequested) {
            if (config.expect() > 0 && received + gaps.dropped() >= config.expect()) {
                return StopReason.EXPECTED;
            }
            buffer.clear();
            // Drain first: under load a datagram is already waiting, and this costs one syscall
            // rather than select + receive.
            SocketAddress source = channel.receive(buffer);
            if (source == null) {
                long timeoutMs = 0; // Selector.select(.., 0) blocks until a wakeup
                if (seenFirst) {
                    long idleLeftNs = config.idleTimeoutMs() * 1_000_000L - (System.nanoTime() - lastRxNs);
                    if (idleLeftNs <= 0) {
                        return StopReason.IDLE;
                    }
                    timeoutMs = Math.max(1, idleLeftNs / 1_000_000L);
                }
                selector.select(key -> { }, timeoutMs);
                continue;
            }
            buffer.flip();
            ParcelEvent event;
            try {
                // Direct, non-array buffer: protobuf-java reads it in place (no copy to byte[]).
                event = ParcelEvent.parseFrom(buffer);
            } catch (InvalidProtocolBufferException e) {
                malformed++;
                continue;
            }
            seenFirst = true;
            // Stamped on receipt, not on completion: a handler may hold parcels for a while.
            lastRxNs = System.nanoTime();

            if (gaps.observe(event.getSeq()) == GapTracker.Arrival.REORDERED) {
                continue; // reported in notes, not recorded twice
            }
            if (gaps.lastGap() > 0) {
                recorder.addDropped(gaps.lastGap());
            }
            received++;
            completion.begin(event.getSeq());
            handler.onParcel(event, completion);
        }
        return StopReason.REQUESTED;
    }

    /** The report's {@code notes} field. */
    String reportNotes() {
        return "reordered=%d; rcvbuf_requested=%d; rcvbuf_granted=%d"
                .formatted(gaps.reordered(), config.rcvbuf(), grantedRcvbuf);
    }

    /** Human-readable notes for the report: what the histogram alone does not say. */
    String notes() {
        return "received=%d dropped=%d reordered=%d malformed=%d lanes=%s rcvbuf_granted=%d"
                .formatted(received, gaps.dropped(), gaps.reordered(), malformed,
                        Arrays.toString(laneCounts), grantedRcvbuf)
                + "; JIT not warmed: the first thousands of parcels ran interpreted/C1 and are included";
    }

    @Override
    public void close() throws IOException {
        selector.close();
        channel.close();
    }
}
