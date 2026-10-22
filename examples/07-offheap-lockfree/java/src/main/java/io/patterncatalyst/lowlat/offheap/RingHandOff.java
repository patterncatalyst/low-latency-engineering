package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.nio.ByteBuffer;
import java.util.function.Supplier;
import org.agrona.concurrent.IdleStrategy;
import org.agrona.concurrent.MessageHandler;
import org.agrona.concurrent.UnsafeBuffer;
import org.agrona.concurrent.ringbuffer.OneToOneRingBuffer;
import org.agrona.concurrent.ringbuffer.RingBufferDescriptor;

/**
 * An Agrona {@link OneToOneRingBuffer} over an {@link UnsafeBuffer} on a direct
 * {@link ByteBuffer}: the scan is written as bytes into memory outside the Java heap, in place
 * ({@code tryClaim}, write, {@code commit}), so a publish allocates nothing and the garbage
 * collector never sees the records. The consumer polls with an {@link IdleStrategy}.
 *
 * <p>The busy-spin strategy keeps the decide thread on its CPU: it never blocks, so the
 * producer's publish is just two ordered stores. That costs a core for as long as the program
 * runs, which is why this is a technique for a pinned, dedicated thread and not a default.
 */
final class RingHandOff implements HandOff {

    private static final int MESSAGE_TYPE = 1;

    private final OneToOneRingBuffer ring;
    private final Supplier<IdleStrategy> idleStrategy;
    private volatile boolean running = true;
    private volatile Throwable failure;
    private Thread decide;

    /**
     * @param records capacity in records; the ring holds {@code records} of 64 bytes (8-byte
     *     header plus the 56-byte scan), so it must be a power of two
     * @param idleStrategy what the consumer does when the ring is empty
     */
    RingHandOff(int records, Supplier<IdleStrategy> idleStrategy) {
        int bytes = records * 64;
        this.ring = new OneToOneRingBuffer(
                new UnsafeBuffer(ByteBuffer.allocateDirect(bytes + RingBufferDescriptor.TRAILER_LENGTH)));
        this.idleStrategy = idleStrategy;
    }

    @Override
    public boolean publish(ParcelEvent event, long rxNs) {
        long serial = Barcode.serial(event.getBarcode()); // before the claim: a throw must not leave one open
        int index = ring.tryClaim(MESSAGE_TYPE, RingScan.LENGTH);
        if (index < 0) {
            return false;
        }
        RingScan.write(ring.buffer(), index, event, rxNs, serial);
        ring.commit(index);
        return true;
    }

    @Override
    public void start(ScanSink sink, ThreadPlacement placement) {
        decide = Thread.ofPlatform().name("decide").unstarted(placement.wrap(() -> consume(sink)));
        decide.setUncaughtExceptionHandler((thread, error) -> failure = error);
        decide.start();
    }

    private void consume(ScanSink sink) {
        RingScan view = new RingScan();
        MessageHandler handler = (type, buffer, index, length) ->
                sink.onScan(view.wrap(buffer, index), System.nanoTime());
        IdleStrategy idle = idleStrategy.get();
        sink.onStart();
        while (running) {
            idle.idle(ring.read(handler));
        }
    }

    @Override
    public Throwable failure() {
        return failure;
    }

    @Override
    public void close() {
        running = false;
        if (decide == null) {
            return;
        }
        try {
            decide.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
