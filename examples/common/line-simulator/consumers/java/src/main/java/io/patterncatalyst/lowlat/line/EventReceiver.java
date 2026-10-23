package io.patterncatalyst.lowlat.line;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.net.StandardProtocolFamily;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.util.Map;
import java.util.Objects;

/**
 * Receives datagrams, decodes them with a {@link Decoder} into events of type {@code E} and
 * records {@code done_ns - intended_emit_ns} for each parcel its {@link EventHandler} completes.
 * {@link LineReceiver} is this class with the protobuf decoder.
 *
 * <p>The constructor binds; {@link #run(EventHandler)} is the single receive thread;
 * {@link #stop()} may be called from any thread. Everything else is owned by the receive thread,
 * and readers must happen-after {@code run} returns (join the thread). If the handler moved the
 * {@link Completion} to another thread, its {@code drain} joins that thread first (see
 * {@link Completion}).
 *
 * @param <E> the decoded event type
 */
public class EventReceiver<E> implements AutoCloseable {

    /** Why {@link #run(EventHandler)} returned. */
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
    private final Decoder<E> decoder;
    private final DatagramChannel channel;
    private final Selector selector;
    private final int grantedRcvbuf;
    private final ByteBuffer buffer = ByteBuffer.allocateDirect(MAX_DATAGRAM);
    private final LatencyRecorder recorder;
    private final WindowedRecorders windows; // null without --window
    private final GapTracker gaps;
    private final Completion completion;
    private final Completion.SeqCell seqCell; // cached: the receive loop never loads completion's fields
    private long received;
    private long malformed;
    private long receiveAllocatedBytes = -1; // -1: not measured
    private volatile boolean stopRequested;

    public EventReceiver(Config config, Decoder<E> decoder) throws IOException {
        this.config = config;
        this.decoder = Objects.requireNonNull(decoder, "decoder");
        this.recorder = LatencyRecorder.singleThreaded(config.example(), config.variant());
        this.windows = config.window() > 0
                ? new WindowedRecorders(config.example(), config.variant(), config.window())
                : null;
        this.gaps = new GapTracker(config.window());
        this.completion = new Completion(recorder, windows);
        this.seqCell = completion.seqCell();
        DatagramChannel ch = DatagramChannel.open(StandardProtocolFamily.INET);
        Selector sel = null;
        try {
            ch.setOption(StandardSocketOptions.SO_RCVBUF, config.rcvbuf());
            ch.bind(config.bindAddress());
            ch.configureBlocking(false);
            sel = Selector.open();
            ch.register(sel, SelectionKey.OP_READ);
        } catch (IOException | RuntimeException e) {
            closeAfter(e, sel);
            closeAfter(e, ch);
            throw e;
        }
        this.channel = ch;
        this.selector = sel;
        this.grantedRcvbuf = ch.getOption(StandardSocketOptions.SO_RCVBUF);
    }

    /** Closes {@code resource} (if opened) on the constructor's failure path; a close failure rides on {@code cause}. */
    private static void closeAfter(Throwable cause, AutoCloseable resource) {
        if (resource == null) {
            return;
        }
        try {
            resource.close();
        } catch (Exception closeFailure) {
            cause.addSuppressed(closeFailure);
        }
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

    /** The first-window and steady recorders, or {@code null} when the config has no window. */
    public WindowedRecorders windows() {
        return windows;
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

    public void stop() {
        stopRequested = true;
        selector.wakeup();
    }

    /**
     * Bytes the receive thread allocated between the start and the end of the receive loop
     * (decode, handler calls made on that thread, selector), or -1 before a run or where the JVM
     * does not report it. Work the handler moves to another thread is not counted.
     */
    public long receiveAllocatedBytes() {
        return receiveAllocatedBytes;
    }

    /**
     * The report's {@code runtime} block for this run: {@link RuntimeInfo#jvm()} plus
     * {@code alloc_bytes_per_parcel}, the receive thread's allocation divided by the parcels
     * received (omitted when unmeasured or nothing was received). Call it after {@code run}.
     */
    public Map<String, Object> runtime() {
        return runtime(Map.of());
    }

    /** As {@link #runtime()}, with {@code extraGc} entries added to the {@code gc} object. */
    public Map<String, Object> runtime(Map<String, ?> extraGc) {
        Map<String, Object> runtime = RuntimeInfo.jvm(extraGc);
        if (receiveAllocatedBytes >= 0 && received > 0) {
            runtime.put("alloc_bytes_per_parcel", (double) receiveAllocatedBytes / received);
        }
        return runtime;
    }

    /**
     * The {@code runtime} block for the window reports: {@link RuntimeInfo#jvm()} only. The
     * allocation counter covers the whole run, so a per-window report must not carry it as if it
     * were that window's figure.
     */
    public Map<String, Object> windowRuntime() {
        return RuntimeInfo.jvm();
    }

    /** As {@link #windowRuntime()}, with {@code extraGc} entries added to the {@code gc} object. */
    public Map<String, Object> windowRuntime(Map<String, ?> extraGc) {
        return RuntimeInfo.jvm(extraGc);
    }

    /**
     * Receives until the expected count, the idle timeout or {@link #stop()}, calling
     * {@code handler} for each new parcel and then {@link EventHandler#drain}. Gaps are booked
     * into the recorder as they appear.
     */
    public StopReason run(EventHandler<E> handler) throws IOException {
        StopReason reason = measuredReceive(handler);
        handler.drain(completion);
        if (windows != null) {
            windows.first().addDropped(gaps.droppedBelowWindow());
            windows.steady().addDropped(gaps.dropped() - gaps.droppedBelowWindow());
        }
        return reason;
    }

    /**
     * The receive loop between two reads of the thread's allocated-bytes counter: the counter is
     * read once before and once after the loop, never per parcel.
     */
    private StopReason measuredReceive(EventHandler<E> handler) throws IOException {
        com.sun.management.ThreadMXBean threads =
                ManagementFactory.getThreadMXBean() instanceof com.sun.management.ThreadMXBean sun
                        && sun.isThreadAllocatedMemorySupported() ? sun : null;
        if (threads == null) {
            return receive(handler);
        }
        long thread = Thread.currentThread().threadId();
        long before = threads.getThreadAllocatedBytes(thread);
        try {
            return receive(handler);
        } finally {
            receiveAllocatedBytes = threads.getThreadAllocatedBytes(thread) - before;
        }
    }

    private StopReason receive(EventHandler<E> handler) throws IOException {
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
            E event;
            try {
                event = decoder.decode(buffer);
            } catch (Decoder.MalformedDatagramException e) {
                malformed++;
                continue;
            }
            seenFirst = true;
            // Stamped on receipt, not on completion: a handler may hold parcels for a while.
            lastRxNs = System.nanoTime();

            long seq = decoder.seq(event);
            if (gaps.observe(seq) == GapTracker.Arrival.REORDERED) {
                continue; // reported in notes, not recorded twice
            }
            if (gaps.lastGap() > 0) {
                recorder.addDropped(gaps.lastGap());
            }
            received++;
            Completion.begin(seqCell, seq);
            handler.onParcel(event, completion);
        }
        return StopReason.REQUESTED;
    }

    /** The report's {@code notes} field. */
    String reportNotes() {
        return "reordered=%d; rcvbuf_requested=%d; rcvbuf_granted=%d"
                .formatted(gaps.reordered(), config.rcvbuf(), grantedRcvbuf);
    }

    /** Human-readable notes: what the histogram alone does not say. */
    String notes() {
        return "received=%d dropped=%d reordered=%d malformed=%d rcvbuf_granted=%d"
                .formatted(received, gaps.dropped(), gaps.reordered(), malformed, grantedRcvbuf)
                + "; JIT not warmed: the first thousands of parcels ran interpreted/C1 and are included";
    }

    @Override
    public void close() throws IOException {
        try (channel; selector) { // closes the selector first, then the channel, even if one throws
            // nothing else to release
        }
    }
}
