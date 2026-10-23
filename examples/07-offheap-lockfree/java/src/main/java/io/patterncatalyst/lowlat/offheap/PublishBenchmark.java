package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.v1.Dimensions;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.util.concurrent.TimeUnit;
import org.openjdk.jmh.annotations.AuxCounters;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Param;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.TearDown;
import org.openjdk.jmh.annotations.Warmup;

/**
 * Allocation on the publish path, per hand-off structure. The benchmark calls the production
 * {@link HandOff#publish} while a consumer thread drains the structure, and the number to read is
 * {@code gc.alloc.rate.norm} (bytes per publish) from {@code -prof gc}: it counts every thread,
 * so the consumer's allocations are in it too. The throughput score is not a latency and is not
 * quoted.
 *
 * <p>The consumer's sink does nothing but add to a field, so what the profiler sees is the
 * structure, not the work behind it.
 */
@BenchmarkMode(Mode.Throughput)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Warmup(iterations = 3, time = 1)
@Measurement(iterations = 5, time = 1)
// Agrona reaches jdk.internal.misc.Unsafe, which JDK 25 does not export by default. The
// analytics switch keeps the fork off the network should a Chronicle class ever load in it.
@Fork(value = 1, jvmArgsAppend = {"--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED",
        "-Dchronicle.analytics.disable=true"})
@State(Scope.Benchmark)
public class PublishBenchmark {

    @Param({"blocking-queue", "linked-queue", "agrona-spsc", "disruptor"})
    public String structure;

    private ParcelEvent event;
    private HandOff handOff;

    /** Consumes and discards. */
    private static final class DiscardSink implements ScanSink {
        @SuppressWarnings("unused") // written so the read of each scan is not dead code
        private long sink;

        @Override
        public void onStart() {
            // nothing to prepare
        }

        @Override
        public void onScan(ScanView scan, long pickupNs) {
            sink += scan.seq();
        }
    }

    @Setup(Level.Trial)
    public void setUp() {
        event = ParcelEvent.newBuilder()
                .setSeq(7)
                .setIntendedEmitNs(1_000)
                .setEncoderTick(7_000)
                .setBarcode("006141410000000071")
                .setWeightG(2_000)
                .setDims(Dimensions.newBuilder().setLengthMm(300).setWidthMm(200).setHeightMm(100))
                .setScanConfidencePermille(990)
                .build();
        handOff = Variant.of(structure).handOff().create(1 << 16);
        handOff.start(new DiscardSink(), ThreadPlacement.UNPINNED);
    }

    @TearDown(Level.Trial)
    public void tearDown() {
        handOff.close();
    }

    /** Publishes the iteration accepted and rejected (ring full); JMH reports them as extra columns. */
    @State(Scope.Thread)
    @AuxCounters(AuxCounters.Type.EVENTS)
    public static class Outcomes {
        public long accepted;
        public long rejected;
    }

    @Benchmark
    public boolean publish(Outcomes outcomes) {
        boolean accepted = handOff.publish(event, System.nanoTime());
        if (accepted) {
            outcomes.accepted++;
        } else {
            outcomes.rejected++;
        }
        return accepted;
    }
}
