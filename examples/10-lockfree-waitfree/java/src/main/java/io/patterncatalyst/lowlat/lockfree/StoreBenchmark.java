package io.patterncatalyst.lowlat.lockfree;

import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.util.concurrent.TimeUnit;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OperationsPerInvocation;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.State;

/**
 * Per-store cost of the two {@code VarHandle} modes in the induction-gap test (observed, not
 * asserted): a release store is a plain {@code mov} on x86-64, a volatile store is followed by a
 * fence ({@code lock addl}) that drains the store buffer. One invocation is {@value #STORES} stores, so
 * a sample is the cost of one store to the clock's resolution.
 *
 * <p>Loop unrolling is off ({@code -XX:LoopUnrollLimit=1}). With the default, C2 unrolls the store loop and
 * keeps one fence per four stores: {@code mem_inst_retired.lock_loads:u} reads 0.25 per store and the
 * volatile store looks like 1.2 ns. With unrolling off the counter reads 1.00 per store and the cost is
 * about 4 ns, the same instruction cost as the C++ {@code xchg}. A benchmark of the fence has to keep
 * the fences it means to measure.
 */
@Fork(jvmArgsAppend = "-XX:LoopUnrollLimit=1")
@State(Scope.Thread)
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
public class StoreBenchmark {

    private static final VarHandle FLAG;

    static {
        try {
            FLAG = MethodHandles.lookup().findVarHandle(StoreBenchmark.class, "flag", long.class);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private static final int STORES = 1000;

    private long flag;
    private long counter;

    /** {@code setRelease}: C++ {@code memory_order_release}. */
    @Benchmark
    @OperationsPerInvocation(STORES)
    public void releaseAcquire() {
        for (int i = 0; i < STORES; i++) {
            FLAG.setRelease(this, ++counter);
        }
    }

    /** {@code setVolatile}: sequentially consistent, C++ {@code memory_order_seq_cst}. */
    @Benchmark
    @OperationsPerInvocation(STORES)
    public void seqCst() {
        for (int i = 0; i < STORES; i++) {
            FLAG.setVolatile(this, ++counter);
        }
    }
}
