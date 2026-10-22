package io.patterncatalyst.lowlat.jvmcosts;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.util.concurrent.TimeUnit;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OperationsPerInvocation;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.Warmup;

/**
 * What one {@link Tracker#decide} costs in heap bytes, with {@code -prof gc} ({@code gc.alloc.rate.norm},
 * bytes per decision). The same call, three outcomes for the {@link DivertDecision} it allocates:
 *
 * <ul>
 *   <li>{@code escaping}: the decision is stored in a field, so it outlives the call and stays on the heap.
 *   <li>{@code scalarReplaced}: the decision is read and dropped inside the loop. Once {@code decide} is
 *       inlined, escape analysis proves it never leaves, and C2 keeps its two fields in registers.
 *   <li>{@code scalarReplacedNoEscapeAnalysis}: the same loop in a fork with {@code -XX:-DoEscapeAnalysis}.
 *       The object is allocated again: the saving came from the analysis, not from the loop.
 * </ul>
 *
 * SampleTime mode, like Ch4: the samples are per-invocation times, never an average. This example reads
 * only the allocation counter, which is exact. One invocation decides {@value #BATCH} parcels.
 */
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 3, time = 300, timeUnit = TimeUnit.MILLISECONDS)
@Measurement(iterations = 5, time = 500, timeUnit = TimeUnit.MILLISECONDS)
@Fork(2)
@State(Scope.Thread)
public class AllocationBenchmark {

    static final int BATCH = 1024;
    private static final long SEED = 42;

    // Non-final: the JIT cannot treat the contents as constants.
    private ParcelEvent[] events;
    private DivertDecision stored;

    @Setup
    public void setup() {
        events = SyntheticParcels.batch(BATCH, SEED);
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public void escaping() {
        for (ParcelEvent event : events) {
            stored = Tracker.decide(event); // a heap write: the object outlives the call
        }
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public long scalarReplaced() {
        return sumOfDecisions(events);
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    @Fork(value = 2, jvmArgsAppend = "-XX:-DoEscapeAnalysis")
    public long scalarReplacedNoEscapeAnalysis() {
        return sumOfDecisions(events);
    }

    private static long sumOfDecisions(ParcelEvent[] parcels) {
        long sum = 0;
        for (ParcelEvent event : parcels) {
            DivertDecision decision = Tracker.decide(event); // read here, never stored or passed on
            sum += decision.lane() + decision.deadlineTick();
        }
        return sum;
    }
}
