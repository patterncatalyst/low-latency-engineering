package io.patterncatalyst.lowlat.bench;

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
import org.openjdk.jmh.infra.Blackhole;

/**
 * JMH, SampleTime mode: the harness times individual invocations and reports
 * percentiles (p0.50 ... p0.9999), not an average.
 *
 * <p>One invocation checks a whole batch of {@value #BATCH} prefixes. SampleTime reads
 * the clock around every invocation, so a call that takes nanoseconds would mostly
 * measure the clock; batching and {@code @OperationsPerInvocation} keep the clock cost
 * negligible and still report time per check digit.
 *
 * <ul>
 *   <li>{@code guarded}: inputs live in {@code @State}, every result goes to a
 *       {@link Blackhole}.
 *   <li>{@code eliminated}: constant input, result kept in a local and dropped. C2 sees
 *       a pure computation with no observable effect and removes it (dead-code
 *       elimination). The number it reports is the cost of the empty loop.
 * </ul>
 */
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 3, time = 200, timeUnit = TimeUnit.MILLISECONDS)
@Measurement(iterations = 5, time = 300, timeUnit = TimeUnit.MILLISECONDS)
@Fork(3)
@State(Scope.Thread)
public class CheckDigitBenchmark {

    static final int BATCH = 1024;
    private static final String CONSTANT_PREFIX = "00614141000000007";

    // Non-final: the JIT cannot treat the contents as constants.
    private String[] prefixes;

    @Setup
    public void setup() {
        prefixes = CheckDigit.prefixes(BATCH);
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public void guarded(Blackhole bh) {
        for (String prefix : prefixes) {
            bh.consume(CheckDigit.of(prefix));
        }
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    @SuppressWarnings("unused") // the discarded result is the point
    public void eliminated() {
        for (int i = 0; i < BATCH; i++) {
            int digit = CheckDigit.of(CONSTANT_PREFIX);
        }
    }
}
