package io.patterncatalyst.lowlat.eliminating;

import java.util.concurrent.TimeUnit;
import net.openhft.affinity.AffinityLock;
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
 * The per-tick due sweep over {@value #PARCELS} in-flight parcels: {@code hubSweepFatRecord} walks an array of
 * references to {@link ParcelState} objects (allocated in a seeded shuffled order, so slot order is not
 * allocation order); {@code hubSweepHotCold} walks two primitive arrays. Both tables hold the same parcels and
 * return the same count (checked in setup); each invocation is one whole sweep. The difference from Ch8's
 * {@code MemorySegment} table is the model: this one is ordinary on-heap objects against primitive arrays.
 */
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 4, time = 1)
@Measurement(iterations = 5, time = 2)
@Fork(1)
public class HubSweepBenchmark {

    static final int PARCELS = 1_000_000;
    static final long TICK = PARCELS / 2;

    abstract static class SweepState {
        RecordTable table;
        private AffinityLock lock;

        void pin() {
            lock = Placement.pinConfigured("bench");
        }

        void release() {
            if (lock != null) {
                lock.close();
            }
        }

        void checkCount() {
            // Parcel i is scanned at tick i and due at i + 1200; about half are due at TICK.
            int expected = (int) (TICK - ParcelState.DIVERT_TICKS + 1);
            if (table.sweepDue(TICK) != expected) {
                throw new IllegalStateException("sweep counted " + table.sweepDue(TICK) + ", expected " + expected);
            }
        }
    }

    @State(Scope.Thread)
    public static class FatRecordState extends SweepState {
        @Setup(Level.Trial)
        public void setup() {
            pin();
            Keys keys = Keys.make(PARCELS, 2026);
            int[] allocationOrder = Keys.shuffledOrder(PARCELS, 42);
            ParcelState[] rows = new ParcelState[PARCELS];
            Scan scan = new Scan();
            for (int slot : allocationOrder) { // object for slot `slot` is the next one on the heap
                rows[slot] = ParcelState.of(scan.of(keys, slot), keys.packed(slot));
            }
            table = ObjectTable.adopt(rows);
            checkCount();
        }

        @TearDown(Level.Trial)
        public void tearDown() {
            release();
        }
    }

    @State(Scope.Thread)
    public static class HotColdState extends SweepState {
        @Setup(Level.Trial)
        public void setup() {
            pin();
            Keys keys = Keys.make(PARCELS, 2026);
            ColumnTable columns = new ColumnTable(PARCELS);
            Scan scan = new Scan();
            for (int i = 0; i < PARCELS; i++) {
                columns.insert(scan.of(keys, i), keys.packed(i));
            }
            table = columns;
            checkCount();
        }

        @TearDown(Level.Trial)
        public void tearDown() {
            release();
        }
    }

    @Benchmark
    public int hubSweepFatRecord(FatRecordState s) {
        return s.table.sweepDue(TICK);
    }

    @Benchmark
    public int hubSweepHotCold(HotColdState s) {
        return s.table.sweepDue(TICK);
    }
}
