package io.patterncatalyst.lowlat.flat;

import java.util.concurrent.TimeUnit;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.TearDown;
import org.openjdk.jmh.annotations.Warmup;

/**
 * The encoder-tick sweep over {@value #PARCELS} in-flight parcels: {@code objectTable} walks an
 * array of references to heap objects, {@code flatTable} walks a {@code MemorySegment} of 24-byte
 * structs. Both tables hold the same parcels and return the same total (checked in setup), and
 * each invocation is one whole sweep, so SampleTime percentiles are percentiles of a sweep.
 *
 * <p>The heap is fixed and pre-touched so no collection starts during a sweep (the sweep itself
 * allocates nothing); the object table's cost is the memory layout, not the collector.
 */
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 4, time = 1)
@Measurement(iterations = 5, time = 2)
@Fork(value = 2, jvmArgsAppend = {"--enable-native-access=ALL-UNNAMED", "-Xms2g", "-Xmx2g", "-XX:+AlwaysPreTouch"})
@State(Scope.Thread)
public class TableBenchmark {

    static final int PARCELS = 1_000_000;

    private ObjectTable objectTable;
    private FlatTable flatTable;
    private long dueTick;

    @Setup(Level.Trial)
    public void setup() {
        TableData data = new TableData(PARCELS, 2026);
        objectTable = new ObjectTable(data.bySlot());
        flatTable = FlatTable.copyOf(data.bySlot());
        dueTick = data.dueTick();
        if (objectTable.sweepDue(dueTick) != flatTable.sweepDue(dueTick)) {
            throw new IllegalStateException("the two tables disagree");
        }
    }

    @TearDown(Level.Trial)
    public void tearDown() {
        flatTable.close();
    }

    @Benchmark
    public long objectTable() {
        return objectTable.sweepDue(dueTick);
    }

    @Benchmark
    public long flatTable() {
        return flatTable.sweepDue(dueTick);
    }
}
