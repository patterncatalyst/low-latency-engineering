package io.patterncatalyst.lowlat.offheap;

import com.lmax.disruptor.EventHandler;
import com.lmax.disruptor.ExceptionHandler;
import com.lmax.disruptor.InsufficientCapacityException;
import com.lmax.disruptor.RingBuffer;
import com.lmax.disruptor.WaitStrategy;
import com.lmax.disruptor.dsl.Disruptor;
import com.lmax.disruptor.dsl.ProducerType;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicReference;

/**
 * An LMAX Disruptor ring of preallocated {@link Slot}s with a single producer. Publishing claims
 * a sequence, overwrites the slot's fields and publishes the sequence; nothing is allocated. The
 * wait strategy decides what the consumer does when the ring is empty: {@code BusySpinWaitStrategy}
 * keeps it running, {@code BlockingWaitStrategy} parks it on a lock and condition.
 */
final class DisruptorHandOff implements HandOff {

    private final int slots;
    private final WaitStrategy waitStrategy;
    private final AtomicReference<Throwable> failure = new AtomicReference<>();
    private Disruptor<Slot> disruptor;
    private RingBuffer<Slot> ring;

    /** @param slots ring size, a power of two */
    DisruptorHandOff(int slots, WaitStrategy waitStrategy) {
        this.slots = slots;
        this.waitStrategy = waitStrategy;
    }

    @Override
    public boolean publish(ParcelEvent event, long rxNs) {
        long sequence;
        try {
            sequence = ring.tryNext();
        } catch (InsufficientCapacityException full) {
            return false;
        }
        try {
            ring.get(sequence).fill(event, rxNs);
        } finally {
            ring.publish(sequence); // always: an unpublished claim would stall the consumer
        }
        return true;
    }

    @Override
    public void start(ScanSink sink, ThreadPlacement placement) {
        ThreadFactory threads = body -> Thread.ofPlatform().name("decide").unstarted(placement.wrap(body));
        disruptor = new Disruptor<>(Slot::new, slots, threads, ProducerType.SINGLE, waitStrategy);
        disruptor.handleEventsWith(new EventHandler<Slot>() {
            @Override
            public void onStart() {
                sink.onStart();
            }

            @Override
            public void onEvent(Slot slot, long sequence, boolean endOfBatch) {
                sink.onScan(slot, System.nanoTime());
            }
        });
        disruptor.setDefaultExceptionHandler(new RecordingExceptionHandler());
        ring = disruptor.start();
    }

    @Override
    public Throwable failure() {
        return failure.get();
    }

    @Override
    public void close() {
        if (disruptor == null) {
            return;
        }
        if (failure.get() != null) {
            disruptor.halt(); // the consumer stopped on its failure: shutdown() would wait for a backlog that never drains
        } else {
            disruptor.shutdown(); // returns once the consumer has handled everything published
        }
    }

    /**
     * Keeps the first failure for {@link #failure()} and, like the Disruptor's
     * {@code FatalExceptionHandler}, rethrows it so the consumer stops, as the ring and queue
     * variants' decide threads do when they die.
     */
    private final class RecordingExceptionHandler implements ExceptionHandler<Slot> {
        @Override
        public void handleEventException(Throwable error, long sequence, Slot event) {
            failure.compareAndSet(null, error);
            throw new IllegalStateException("decide thread failed at sequence " + sequence, error);
        }

        @Override
        public void handleOnStartException(Throwable error) {
            failure.compareAndSet(null, error);
            throw new IllegalStateException("decide thread failed to start", error);
        }

        @Override
        public void handleOnShutdownException(Throwable error) {
            failure.compareAndSet(null, error);
        }
    }
}
