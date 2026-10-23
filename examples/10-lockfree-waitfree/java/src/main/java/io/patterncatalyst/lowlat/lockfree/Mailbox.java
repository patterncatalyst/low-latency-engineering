package io.patterncatalyst.lowlat.lockfree;

import java.util.concurrent.ArrayBlockingQueue;
import org.agrona.concurrent.ManyToOneConcurrentArrayQueue;

/**
 * The data path from the cameras' receive threads to the tracker: many producers, one consumer. It
 * carries scans only. Divert commands leave the tracker on their own socket ({@link CommandChannel}),
 * so a flood of scans can never queue ahead of a command.
 *
 * <ul>
 *   <li>{@link Blocking}: {@link ArrayBlockingQueue}, one lock for producers and consumer; the
 *       consumer parks in {@code take()} when the queue is empty and a producer must wake it.
 *   <li>{@link Spinning}: Agrona's {@link ManyToOneConcurrentArrayQueue}, whose producers claim a slot
 *       with a CAS on the tail and publish it with an ordered store; the consumer polls.
 * </ul>
 */
sealed interface Mailbox {

    /** Producer: false when full (the belt does not wait, so there is no blocking offer). */
    boolean offer(Scan scan);

    /** Consumer: the next scan, waiting for one; {@link Scan#END} ends the run. */
    Scan take() throws InterruptedException;

    final class Blocking implements Mailbox {
        private final ArrayBlockingQueue<Scan> queue;

        Blocking(int capacity) {
            this.queue = new ArrayBlockingQueue<>(capacity);
        }

        @Override
        public boolean offer(Scan scan) {
            return queue.offer(scan);
        }

        @Override
        public Scan take() throws InterruptedException {
            return queue.take();
        }
    }

    final class Spinning implements Mailbox {
        private final ManyToOneConcurrentArrayQueue<Scan> queue;

        Spinning(int capacity) {
            this.queue = new ManyToOneConcurrentArrayQueue<>(capacity);
        }

        @Override
        public boolean offer(Scan scan) {
            return queue.offer(scan);
        }

        @Override
        public Scan take() {
            Scan scan;
            while ((scan = queue.poll()) == null) {
                Thread.onSpinWait();
            }
            return scan;
        }
    }
}
