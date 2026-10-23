package io.patterncatalyst.lowlat.lockfree;

import java.util.concurrent.atomic.AtomicLong;
import org.agrona.concurrent.ManyToOneConcurrentArrayQueue;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.State;

/** Build wiring for Ch10 (S4): proves Agrona and JMH resolve and compile. Replaced in S6. */
@State(Scope.Thread)
public class Wiring {
    private final AtomicLong sequence = new AtomicLong();
    private final ManyToOneConcurrentArrayQueue<Long> queue = new ManyToOneConcurrentArrayQueue<>(8);

    /** Claims the next sequence with one fetch-add and passes it through the Agrona MPSC queue. */
    @Benchmark
    public long claim() {
        final long claimed = sequence.getAndIncrement();
        queue.offer(claimed);
        final Long out = queue.poll();
        return out == null ? -1L : out;
    }
}
