package io.patterncatalyst.lowlat.eliminating;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.eliminating.Tracker.Tracked;
import java.util.function.IntFunction;
import java.util.stream.Stream;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

/** Tracker logic for every shape: insert, update, erase, slot reuse, sweep, expire. */
class TrackerTest {

    record Shape(String name, IntFunction<Tracker> make) {
        @Override
        public String toString() {
            return name;
        }
    }

    static Stream<Arguments> shapes() {
        return Stream.of(
                Arguments.of(new Shape("node-map", NodeMapTracker::new)),
                Arguments.of(new Shape("flat-map (object rows)", n -> new FlatMapTracker(n, new ObjectTable(n)))),
                Arguments.of(new Shape("flat-map (hot/cold columns)", FlatMapTracker::withColumns)));
    }

    private static final long TICKS = ParcelState.DIVERT_TICKS;

    @ParameterizedTest
    @MethodSource("shapes")
    void insertsUpdatesAndFinds(Shape shape) {
        Tracker tracker = shape.make().apply(16);
        Keys keys = Keys.make(8, 1);
        Scan scan = new Scan();
        for (int i = 0; i < 8; i++) {
            assertEquals(Tracked.INSERTED, tracker.track(scan.of(keys, i)));
        }
        assertEquals(8, tracker.size());
        assertEquals(Tracked.UPDATED, tracker.track(scan.of(keys, 3))); // same barcode: no second entry
        assertEquals(8, tracker.size());
        for (int i = 0; i < 8; i++) {
            assertEquals(ParcelState.IN_FLIGHT, tracker.findState(keys.text(i)));
        }
        assertEquals(ParcelState.EMPTY, tracker.findState("000000000000000001"));
        scan.of(keys, 0).barcode = "not-a-barcode";
        assertEquals(Tracked.REJECTED, tracker.track(scan));
        assertEquals(8, tracker.size());
    }

    @ParameterizedTest
    @MethodSource("shapes")
    void rescanMovesTheDueTick(Shape shape) {
        Tracker tracker = shape.make().apply(4);
        Keys keys = Keys.make(1, 1);
        Scan scan = new Scan().of(keys, 0);
        scan.tick = 100;
        tracker.track(scan);
        assertEquals(0, tracker.sweepDue(100 + TICKS - 1));
        assertEquals(1, tracker.sweepDue(100 + TICKS));
        scan.tick = 5_000; // scanned again further down the belt: due later
        assertEquals(Tracked.UPDATED, tracker.track(scan));
        assertEquals(0, tracker.sweepDue(100 + TICKS));
        assertEquals(1, tracker.sweepDue(5_000 + TICKS));
    }

    @ParameterizedTest
    @MethodSource("shapes")
    void eraseAndSlotReuse(Shape shape) {
        Tracker tracker = shape.make().apply(8);
        Keys keys = Keys.make(6, 2);
        Scan scan = new Scan();
        for (int i = 0; i < 4; i++) {
            tracker.track(scan.of(keys, i));
        }
        assertTrue(tracker.erase(keys.text(1)));
        assertFalse(tracker.erase(keys.text(1))); // already gone
        assertEquals(ParcelState.EMPTY, tracker.findState(keys.text(1)));
        assertEquals(3, tracker.size());
        assertEquals(Tracked.INSERTED, tracker.track(scan.of(keys, 4))); // a freed slot is reused
        assertEquals(4, tracker.size());
        for (int i : new int[] {0, 2, 3, 4}) {
            assertEquals(ParcelState.IN_FLIGHT, tracker.findState(keys.text(i)));
        }
    }

    @ParameterizedTest
    @MethodSource("shapes")
    void sweepCountsOnlyWhatIsDue(Shape shape) {
        Tracker tracker = shape.make().apply(64);
        Keys keys = Keys.make(50, 3);
        Scan scan = new Scan();
        for (int i = 0; i < 50; i++) {
            tracker.track(scan.of(keys, i)); // scan tick i, due at i + 1200
        }
        assertEquals(0, tracker.sweepDue(TICKS - 1));
        assertEquals(1, tracker.sweepDue(TICKS));
        assertEquals(25, tracker.sweepDue(TICKS + 24));
        assertEquals(50, tracker.sweepDue(1_000_000));
        tracker.erase(keys.text(0));
        assertEquals(49, tracker.sweepDue(1_000_000)); // an erased slot is not due
    }

    @ParameterizedTest
    @MethodSource("shapes")
    void expireErasesWhatIsDue(Shape shape) {
        Tracker tracker = shape.make().apply(64);
        Keys keys = Keys.make(50, 4);
        Scan scan = new Scan();
        for (int i = 0; i < 50; i++) {
            tracker.track(scan.of(keys, i));
        }
        assertEquals(10, tracker.expire(TICKS + 9));
        assertEquals(40, tracker.size());
        for (int i = 0; i < 10; i++) {
            assertEquals(ParcelState.EMPTY, tracker.findState(keys.text(i)));
        }
        for (int i = 10; i < 50; i++) {
            assertEquals(ParcelState.IN_FLIGHT, tracker.findState(keys.text(i)));
        }
        assertEquals(0, tracker.expire(TICKS + 9)); // nothing more is due
    }

    @ParameterizedTest
    @MethodSource("shapes")
    void slidingWindowKeepsTheLineInFlightCount(Shape shape) {
        int ring = 1_000;
        int window = 100;
        Tracker tracker = shape.make().apply(window + 8);
        Keys keys = Keys.make(ring, 5);
        Scan scan = new Scan();
        for (int i = ring - window; i < ring; i++) {
            tracker.track(scan.of(keys, i));
        }
        for (int i = 0; i < 5 * ring; i++) {
            int pos = i % ring;
            assertEquals(Tracked.INSERTED, tracker.track(scan.of(keys, pos)));
            assertTrue(tracker.erase(keys.text((pos + ring - window) % ring)));
            assertEquals(window, tracker.size());
        }
    }

    @ParameterizedTest
    @MethodSource("shapes")
    void objectAndColumnTablesAgreeOnTheSweep(Shape shape) {
        Tracker tracker = shape.make().apply(2_100);
        Keys keys = Keys.make(2_000, 6);
        Scan scan = new Scan();
        for (int i = 0; i < 2_000; i++) {
            tracker.track(scan.of(keys, i));
        }
        tracker.erase(keys.text(10));
        assertEquals(0, tracker.sweepDue(1_199));
        assertEquals(1, tracker.sweepDue(1_200));
        assertEquals(1_999, tracker.sweepDue(5_000));
    }
}
