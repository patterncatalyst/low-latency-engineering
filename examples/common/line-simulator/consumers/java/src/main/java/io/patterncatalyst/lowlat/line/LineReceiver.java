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
final class LineReceiver implements AutoCloseable {

    /** Why {@link #run()} returned. */
    enum StopReason { EXPECTED, IDLE, REQUESTED }

    /** A negative latency means the producer and this JVM are not on one monotonic clock. */
    static final class NegativeLatencyException extends IllegalStateException {
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
    private final long[] laneCounts = new long[Lanes.LANES];
    private long received;
    private long malformed;
    private volatile boolean stopRequested;

    LineReceiver(Config config) throws IOException {
        this.config = config;
        this.recorder = LatencyRecorder.singleThreaded(config.example(), config.variant());
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

    int grantedRcvbuf() {
        return grantedRcvbuf;
    }

    InetSocketAddress localAddress() throws IOException {
        return (InetSocketAddress) channel.getLocalAddress();
    }

    LatencyRecorder recorder() {
        return recorder;
    }

    GapTracker gaps() {
        return gaps;
    }

    long received() {
        return received;
    }

    long malformed() {
        return malformed;
    }

    long[] laneCounts() {
        return laneCounts.clone();
    }

    void stop() {
        stopRequested = true;
        selector.wakeup();
    }

    StopReason run() throws IOException {
        long lastRxNs = 0;
        boolean seenFirst = false;
        while (!stopRequested) {
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
            lastRxNs = System.nanoTime();

            if (gaps.observe(event.getSeq()) == GapTracker.Arrival.REORDERED) {
                continue; // reported in notes, not recorded twice
            }
            if (gaps.lastGap() > 0) {
                recorder.addDropped(gaps.lastGap());
            }
            laneCounts[Lanes.laneOf(event.getBarcode())]++; // the r01 "handle" step
            long doneNs = System.nanoTime();
            long latencyNs = doneNs - event.getIntendedEmitNs();
            if (latencyNs < 0) {
                throw new NegativeLatencyException("negative latency " + latencyNs + " ns for seq "
                        + event.getSeq() + ": intended_emit_ns is ahead of this JVM's System.nanoTime(); "
                        + "producer and consumer must run on one host (one CLOCK_MONOTONIC)");
            }
            recorder.record(latencyNs);
            received++;
            if (config.expect() > 0 && received + gaps.dropped() >= config.expect()) {
                return StopReason.EXPECTED;
            }
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
