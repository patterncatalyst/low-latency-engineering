package io.patterncatalyst.lowlat.lockfree;

import com.google.protobuf.InvalidProtocolBufferException;
import io.patterncatalyst.lowlat.line.v1.DivertCommand;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.InetSocketAddress;
import java.net.StandardProtocolFamily;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.ClosedChannelException;
import java.nio.channels.DatagramChannel;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The actuator end of the command path: a thread that blocks on the command socket, counts the divert
 * commands and records how long each took from the tracker's decision to its arrival. It blocks in the
 * kernel and never spins, so it is not one of the pinned threads.
 */
final class DivertListener implements AutoCloseable {

    private final DatagramChannel channel;
    private final LatencyRecorder latency;
    private final AtomicLong received = new AtomicLong();
    private final Thread thread;
    private volatile Throwable failure;

    DivertListener(String example, String variant) throws IOException {
        this.channel = DatagramChannel.open(StandardProtocolFamily.INET);
        try {
            channel.setOption(StandardSocketOptions.SO_RCVBUF, 4 << 20);
            channel.bind(new InetSocketAddress("127.0.0.1", 0));
        } catch (IOException | RuntimeException e) {
            channel.close();
            throw e;
        }
        this.latency = LatencyRecorder.singleThreaded(example, variant);
        this.thread = Thread.ofPlatform().name("diverter").uncaughtExceptionHandler((t, error) -> failure = error).unstarted(this::listen);
        thread.start();
    }

    private void listen() {
        ByteBuffer buffer = ByteBuffer.allocateDirect(128);
        try {
            while (true) {
                buffer.clear();
                channel.receive(buffer);
                long arrivedNs = System.nanoTime();
                buffer.flip();
                DivertCommand command = DivertCommand.parseFrom(buffer);
                long latencyNs = arrivedNs - command.getDecidedNs();
                if (latencyNs < 0) {
                    throw new IllegalStateException("negative divert latency " + latencyNs + " ns: decided_ns is ahead of this JVM's "
                            + "System.nanoTime(); producer and consumer must run on one host (one CLOCK_MONOTONIC)");
                }
                latency.record(latencyNs);
                received.incrementAndGet();
            }
        } catch (ClosedChannelException closed) {
            // close() ends the listener
        } catch (InvalidProtocolBufferException e) {
            throw new IllegalStateException("not a DivertCommand", e);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    InetSocketAddress address() throws IOException {
        return (InetSocketAddress) channel.getLocalAddress();
    }

    /** Commands that have arrived so far. */
    long received() {
        return received.get();
    }

    Throwable failure() {
        return failure;
    }

    /** The command-latency recorder; read it after {@link #close()}, which joins the listener. */
    LatencyRecorder latency() {
        return latency;
    }

    /** Closes the socket and joins the listener, so the recorder is safe to read. Idempotent. */
    @Override
    public void close() throws IOException {
        channel.close();
        try {
            thread.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
