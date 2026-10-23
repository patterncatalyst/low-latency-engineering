package io.patterncatalyst.lowlat.eliminating;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.management.ThreadMXBean;
import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.openjdk.jol.info.ClassLayout;

/** Object layout (JOL), counter spacing and exact allocation, all deterministic. */
class LayoutAndAllocationTest {

    @Test
    void parcelStateIsAFatObjectAndTheHotColumnsAreNineBytes() {
        long instance = ClassLayout.parseClass(ParcelState.class).instanceSize();
        assertTrue(instance >= 88 && instance <= 112, "ParcelState is about 100 bytes per parcel, was " + instance);
        // The sweep reads dueTick (8 B) and state (1 B) from the columns: 9 bytes against ~100 for the object.
        assertEquals(9, Long.BYTES + Byte.BYTES);
        assertTrue(instance / 9 >= 9, "the object is at least 9x the bytes the sweep needs");
    }

    @Test
    void counterLayoutsAreSpacedAsNamed() {
        CameraCounters adjacent = new CameraCounters(CameraCounters.ADJACENT);
        CameraCounters line = new CameraCounters(CameraCounters.LINE_PADDED);
        CameraCounters pair = new CameraCounters(CameraCounters.PAIR_PADDED);
        assertEquals(16, 8 * (adjacent.readIndex(1) - adjacent.readIndex(0))); // 4 cameras per 64-byte line
        assertEquals(64, 8 * (line.readIndex(1) - line.readIndex(0)));
        assertEquals(128, 8 * (pair.readIndex(1) - pair.readIndex(0)));
        // Any two cameras at least 128 bytes apart never share a 64-byte line or an aligned 128-byte pair.
        assertTrue(8 * (pair.readIndex(CameraCounters.CAMERAS - 1) - pair.readIndex(0)) >= 128 * (CameraCounters.CAMERAS - 1));
    }

    @Test
    void everyCameraKeepsItsOwnCountUnderConcurrentWriters() throws InterruptedException {
        long increments = 200_000;
        CameraCounters counters = new CameraCounters(CameraCounters.PAIR_PADDED);
        List<Thread> cameras = new ArrayList<>();
        for (int c = 0; c < CameraCounters.CAMERAS; c++) {
            int camera = c;
            Thread t = new Thread(() -> {
                for (long i = 0; i < increments; i++) {
                    if (i % 32 == 31) {
                        counters.bumpNoRead(camera);
                    } else {
                        counters.bumpRead(camera);
                    }
                }
            });
            cameras.add(t);
            t.start();
        }
        for (Thread t : cameras) {
            t.join(); // the join is the happens-before edge for the reads below
        }
        for (int c = 0; c < CameraCounters.CAMERAS; c++) {
            assertEquals(increments, counters.total(c));
            assertEquals(increments / 32, counters.noReads(c));
        }
    }

    private static long allocatedBy(Runnable work) {
        ThreadMXBean bean = (ThreadMXBean) ManagementFactory.getThreadMXBean();
        long before = bean.getCurrentThreadAllocatedBytes();
        work.run();
        return bean.getCurrentThreadAllocatedBytes() - before;
    }

    @Test
    void flatMapAllocatesNothingPerInsertAndNodeMapAllocatesEachNode() {
        int n = 2_000;
        Keys keys = Keys.make(n, 8);
        Scan scan = new Scan();
        NodeMapTracker node = new NodeMapTracker(n + 64);
        FlatMapTracker flat = FlatMapTracker.withColumns(n + 64);
        // Warm both once so class loading and lazy initialisation are outside the counted region.
        for (int i = 0; i < n; i++) {
            node.track(scan.of(keys, i));
            flat.track(scan.of(keys, i));
            node.erase(keys.text(i));
            flat.erase(keys.text(i));
        }
        long nodeBytes = allocatedBy(() -> {
            for (int i = 0; i < n; i++) {
                node.track(scan.of(keys, i));
            }
        });
        long flatBytes = allocatedBy(() -> {
            for (int i = 0; i < n; i++) {
                flat.track(scan.of(keys, i));
            }
        });
        assertTrue(nodeBytes / n >= 64, "node-map allocates at least 64 B per insert, was " + nodeBytes / n);
        assertEquals(0, flatBytes, "flat-map insert allocates nothing after construction");
        long eraseBytes = allocatedBy(() -> {
            for (int i = 0; i < n; i++) {
                flat.erase(keys.text(i));
            }
        });
        assertEquals(0, eraseBytes);
    }
}
