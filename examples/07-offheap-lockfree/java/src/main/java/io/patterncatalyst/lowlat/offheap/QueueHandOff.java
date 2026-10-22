package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * The idiomatic JDK hand-off: a {@link BlockingQueue} of immutable {@link Scan}s and a consumer
 * that blocks in {@code take()}. It is correct and simple, and the baseline of this example.
 *
 * <p>An empty queue parks the consumer: the thread leaves the CPU, and the producer's next
 * {@code offer} has to wake it through the kernel. That wake-up is where the hand-off latency and
 * the voluntary context switches come from. {@link #arrayBacked} stores the elements in one
 * preallocated array; {@link #linkedBacked} allocates a node per element on top of the {@code Scan}.
 */
final class QueueHandOff implements HandOff {

    private final BlockingQueue<Scan> queue;
    private volatile Throwable failure;
    private Thread decide;

    private QueueHandOff(BlockingQueue<Scan> queue) {
        this.queue = queue;
    }

    static QueueHandOff arrayBacked(int capacity) {
        return new QueueHandOff(new ArrayBlockingQueue<>(capacity));
    }

    static QueueHandOff linkedBacked(int capacity) {
        return new QueueHandOff(new LinkedBlockingQueue<>(capacity));
    }

    @Override
    public boolean publish(ParcelEvent event, long rxNs) {
        return queue.offer(Scan.of(event, rxNs));
    }

    @Override
    public void start(ScanSink sink, ThreadPlacement placement) {
        decide = Thread.ofPlatform().name("decide").unstarted(placement.wrap(() -> consume(sink)));
        decide.setUncaughtExceptionHandler((thread, error) -> failure = error);
        decide.start();
    }

    private void consume(ScanSink sink) {
        sink.onStart();
        try {
            while (true) {
                Scan scan = queue.take();
                sink.onScan(scan, System.nanoTime());
            }
        } catch (InterruptedException stop) {
            // close() interrupts the consumer once everything published has been handled
        }
    }

    @Override
    public Throwable failure() {
        return failure;
    }

    @Override
    public void close() {
        if (decide == null) {
            return;
        }
        decide.interrupt();
        try {
            decide.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
