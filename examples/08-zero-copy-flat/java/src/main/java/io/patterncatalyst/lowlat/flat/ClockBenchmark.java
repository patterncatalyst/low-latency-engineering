package io.patterncatalyst.lowlat.flat;

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
import org.openjdk.jmh.annotations.TearDown;
import org.openjdk.jmh.annotations.Warmup;

/**
 * One clock read three ways: {@code System.nanoTime()} (an intrinsic), the standard FFM downcall
 * to {@code clock_gettime} and the critical downcall. SampleTime percentiles of the time per
 * read (one invocation reads {@value #BATCH} times). Observed, not asserted: the order is what the
 * chapter explains, the margins depend on the CPU.
 */
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 4, time = 500, timeUnit = TimeUnit.MILLISECONDS)
@Measurement(iterations = 5, time = 500, timeUnit = TimeUnit.MILLISECONDS)
@Fork(value = 2, jvmArgsAppend = "--enable-native-access=ALL-UNNAMED")
@State(Scope.Thread)
public class ClockBenchmark {

    static final int BATCH = 1024;

    private ClockGettime clock;

    @Setup
    public void setup() {
        clock = new ClockGettime();
    }

    @TearDown
    public void tearDown() {
        clock.close();
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public long nanoTime() {
        long sum = 0;
        for (int i = 0; i < BATCH; i++) {
            sum += System.nanoTime();
        }
        return sum;
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public long downcallStandard() {
        long sum = 0;
        for (int i = 0; i < BATCH; i++) {
            sum += clock.standard();
        }
        return sum;
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public long downcallCritical() {
        long sum = 0;
        for (int i = 0; i < BATCH; i++) {
            sum += clock.critical();
        }
        return sum;
    }
}
