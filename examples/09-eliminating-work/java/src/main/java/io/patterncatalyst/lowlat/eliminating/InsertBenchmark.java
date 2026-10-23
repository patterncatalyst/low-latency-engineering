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
 * One tracked parcel at line scale: {@code track()} a new barcode and {@code erase()} the one diverted
 * {@value #WINDOW} parcels earlier, so {@value #WINDOW} stay in flight (Ch2's line table). Run with the gc
 * profiler: {@code gc.alloc.rate.norm} is bytes allocated per insert-and-erase pair, exact.
 */
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 3, time = 1)
@Measurement(iterations = 5, time = 1)
@Fork(1)
public class InsertBenchmark {

    static final int RING = 1 << 16;
    static final int WINDOW = 4_800;

    /** A tracker preloaded with the window and a ring of keys to cycle through. */
    abstract static class RingState {
        final Keys keys = Keys.make(RING, 2026);
        final Scan scan = new Scan();
        int pos;
        private AffinityLock lock;
        abstract Tracker tracker();

        void fill() {
            lock = Placement.pinConfigured("bench");
            for (int i = RING - WINDOW; i < RING; i++) {
                tracker().track(scan.of(keys, i));
            }
        }

        void release() {
            if (lock != null) {
                lock.close();
            }
        }

        int step() {
            int p = pos;
            pos = (p + 1) & (RING - 1);
            tracker().track(scan.of(keys, p));
            tracker().erase(keys.text((p - WINDOW) & (RING - 1)));
            return tracker().size();
        }
    }

    @State(Scope.Thread)
    public static class NodeMapState extends RingState {
        private final NodeMapTracker tracker = new NodeMapTracker(WINDOW + 64);

        @Override
        Tracker tracker() {
            return tracker;
        }

        @Setup(Level.Trial)
        public void setup() {
            fill();
        }

        @TearDown(Level.Trial)
        public void tearDown() {
            release();
        }
    }

    @State(Scope.Thread)
    public static class FlatMapState extends RingState {
        private final FlatMapTracker tracker = FlatMapTracker.withColumns(WINDOW + 64);

        @Override
        Tracker tracker() {
            return tracker;
        }

        @Setup(Level.Trial)
        public void setup() {
            fill();
        }

        @TearDown(Level.Trial)
        public void tearDown() {
            release();
        }
    }

    @Benchmark
    public int insertNodeMap(NodeMapState s) {
        return s.step();
    }

    @Benchmark
    public int insertFlatMap(FlatMapState s) {
        return s.step();
    }
}
