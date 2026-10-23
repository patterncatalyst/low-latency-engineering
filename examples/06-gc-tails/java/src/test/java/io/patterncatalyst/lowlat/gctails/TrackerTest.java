package io.patterncatalyst.lowlat.gctails;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.line.Lanes;
import java.lang.management.ManagementFactory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class TrackerTest {

    /** A small workload: 2 MB of manifest, 100 parcels in flight, 5 MB/s at 1 kHz. */
    private static Settings small() {
        return new Settings(1_000, 2L << 20, 1024, 5L << 20, 100, 4);
    }

    @Test
    void settingsSizeTheRingAndTheHistory() {
        Settings s = small();
        assertEquals((2L << 20) / (1024 + Settings.ENTRY_OVERHEAD_BYTES), s.manifestEntries());
        assertEquals(100, s.inFlightParcels());
        // 5 MiB/s at 1 kHz is about 5.2 kB a parcel: 10 samples of about 560 B each
        assertEquals(10, s.samplesPerParcel());
    }

    @ParameterizedTest
    @ValueSource(longs = {0, 1, 123_456_789, 999_999_999, 1_000_000_001})
    void syntheticBarcodesAreLaneable(long n) {
        String barcode = Tracker.syntheticBarcode(n);
        assertEquals(18, barcode.length());
        assertTrue(Lanes.laneOf(barcode) < Lanes.LANES);
    }

    @Test
    void populateFillsTheManifestAndTheInFlightTableStaysBounded() {
        Tracker tracker = new Tracker(small());
        tracker.populate();
        for (int i = 0; i < 1_000; i++) {
            tracker.track(Tracker.syntheticBarcode(i), i, 2_000);
        }
        assertEquals(small().inFlightParcels(), tracker.inFlightSize());
        assertTrue(tracker.manifestEntries() > 1_000);
    }

    @Test
    void trackReturnsTheLaneOfTheBarcode() {
        Tracker tracker = new Tracker(small());
        String barcode = Tracker.syntheticBarcode(77);
        assertEquals(Lanes.laneOf(barcode), tracker.track(barcode, 1, 2_000));
    }

    @Test
    void eachParcelAllocatesAboutTheTargetHistory() {
        Settings s = small();
        Tracker tracker = new Tracker(s);
        tracker.populate();
        for (int i = 0; i < 2_000; i++) {
            tracker.track(Tracker.syntheticBarcode(i), i, 2_000);
        }
        com.sun.management.ThreadMXBean threads = (com.sun.management.ThreadMXBean) ManagementFactory.getThreadMXBean();
        long thread = Thread.currentThread().threadId();
        int parcels = 2_000;
        long before = threads.getThreadAllocatedBytes(thread);
        for (int i = 0; i < parcels; i++) {
            tracker.track(Tracker.syntheticBarcode(i), i, 2_000);
        }
        long perParcel = (threads.getThreadAllocatedBytes(thread) - before) / parcels;
        long target = s.allocBytesPerSecond() / s.rate();
        // history + manifest entry + in-flight state: at least the target, not more than twice it
        assertTrue(perParcel >= target, "allocated " + perParcel + " B per parcel, target " + target);
        assertTrue(perParcel <= 2 * target, "allocated " + perParcel + " B per parcel, target " + target);
    }
}
