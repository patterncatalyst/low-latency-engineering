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
 * {@code findState()} of a parcel in a hub tracker of {@value #PARCELS} parcels, the keys visited in a shuffled
 * order (not the insertion order). Each invocation is one lookup. The lookup key strings are built once, so
 * their hash codes are cached: on the line a barcode arrives as a new String and pays the hash too, which
 * makes this a conservative measure of the node map.
 *
 * <p>The heap is fixed and pre-touched (see verify.sh) so no collection starts during a run.
 */
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 3, time = 2)
@Measurement(iterations = 5, time = 2)
@Fork(1)
public class HubLookupBenchmark {

    static final int PARCELS = 1_000_000;

    abstract static class HubState {
        Keys lookups;
        int next;
        private AffinityLock lock;

        void build(Tracker tracker) {
            lock = Placement.pinConfigured("bench");
            Keys insertion = Keys.make(PARCELS, 2026);
            Scan scan = new Scan();
            for (int i = 0; i < PARCELS; i++) {
                tracker.track(scan.of(insertion, i));
            }
            lookups = Keys.makeLookup(PARCELS, 2026, 42);
        }

        void release() {
            if (lock != null) {
                lock.close();
            }
        }

        int advance() {
            int j = next;
            next = j + 1 == PARCELS ? 0 : j + 1;
            return j;
        }
    }

    @State(Scope.Thread)
    public static class NodeMapState extends HubState {
        NodeMapTracker tracker;

        @Setup(Level.Trial)
        public void setup() {
            tracker = new NodeMapTracker(PARCELS + PARCELS / 16);
            build(tracker);
        }

        @TearDown(Level.Trial)
        public void tearDown() {
            release();
        }
    }

    @State(Scope.Thread)
    public static class FlatMapState extends HubState {
        FlatMapTracker tracker;

        @Setup(Level.Trial)
        public void setup() {
            tracker = FlatMapTracker.withColumns(PARCELS + PARCELS / 16);
            build(tracker);
        }

        @TearDown(Level.Trial)
        public void tearDown() {
            release();
        }
    }

    @Benchmark
    public byte hubLookupNodeMap(NodeMapState s) {
        return s.tracker.findState(s.lookups.text(s.advance()));
    }

    @Benchmark
    public byte hubLookupFlatMap(FlatMapState s) {
        // The packed key: on the line, Sscc.pack of the arriving barcode is part of the cost and is measured there.
        return s.tracker.findState(s.lookups.packed(s.advance()));
    }
}
