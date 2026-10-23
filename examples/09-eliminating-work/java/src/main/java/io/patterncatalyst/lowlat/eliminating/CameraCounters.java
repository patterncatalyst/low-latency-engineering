package io.patterncatalyst.lowlat.eliminating;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.VarHandle;

/**
 * Per-camera counters for the five scan-tunnel cameras: each camera has a read count and a no-read count, written
 * by that camera's thread only, sampled by a telemetry thread.
 *
 * <p>The counters live in one {@link MemorySegment} allocated with {@code arena.allocate(size, 128)}, the Ch8
 * idiom, because a heap array's alignment cannot be controlled: its base sits at an arbitrary 8-byte offset from a
 * cache line, so "adjacent" counters would straddle two lines at a different place on every run. The segment
 * starts on a 128-byte boundary, so the layout is exact:
 * <ul>
 * <li>{@link Layout#ADJACENT}: the five read counters side by side in the first 64-byte line (bytes 0 to 39),
 * the five no-read counters in the second line (bytes 64 to 103). False sharing by construction.</li>
 * <li>{@link Layout#LINE_PADDED}: each camera owns a 64-byte line.</li>
 * <li>{@link Layout#PAIR_PADDED}: each camera owns a 128-byte line pair.</li>
 * </ul>
 *
 * <p>Access goes through the {@link VarHandle} of {@link ValueLayout#JAVA_LONG}: plain read plus release store for
 * the single writer, {@code getAndAdd} for the contrast run, a volatile read for the telemetry thread. The padding
 * is not idiomatic Java: it is a measured latency construct, and the JDK's own answer for a contended sum is
 * {@link java.util.concurrent.atomic.LongAdder} (one total, not one value per camera).
 */
public final class CameraCounters {

    public static final int CAMERAS = 5;

    /** Where each camera's two counters sit, in bytes from the (128-byte-aligned) start of the segment. */
    public enum Layout {
        ADJACENT(8, 64),
        LINE_PADDED(64, 8),
        PAIR_PADDED(128, 8);

        private final long cameraStride;
        private final long noReadOffset;

        Layout(long cameraStride, long noReadOffset) {
            this.cameraStride = cameraStride;
            this.noReadOffset = noReadOffset;
        }

        /** Bytes between neighbouring cameras' read counters. */
        public long cameraStride() {
            return cameraStride;
        }

        public long readOffset(int camera) {
            return camera * cameraStride;
        }

        public long noReadOffset(int camera) {
            return readOffset(camera) + noReadOffset;
        }

        /** Bytes of the segment, with one trailing line pair so nothing shares a line with the next allocation. */
        long segmentBytes() {
            return noReadOffset(CAMERAS - 1) + Long.BYTES + 128;
        }
    }

    private static final VarHandle LONG = ValueLayout.JAVA_LONG.varHandle();

    private final Layout layout;
    private final MemorySegment cells;

    public CameraCounters(Layout layout) {
        this.layout = layout;
        // Arena.ofAuto: any thread may access it, and the collector frees it; the segment is zero-filled.
        this.cells = Arena.ofAuto().allocate(layout.segmentBytes(), 128);
    }

    public Layout layout() {
        return layout;
    }

    /** Address of the segment, for the layout test and the report. */
    public long baseAddress() {
        return cells.address();
    }

    /** Single writer: a plain read and a release store, no read-modify-write (a plain store on x86). */
    public void bumpRead(int camera) {
        bump(layout.readOffset(camera));
    }

    public void bumpNoRead(int camera) {
        bump(layout.noReadOffset(camera));
    }

    private void bump(long offset) {
        LONG.setRelease(cells, offset, (long) LONG.get(cells, offset) + 1);
    }

    /** The same increment as an atomic read-modify-write ({@code lock xadd} on x86), for the contrast run. */
    public void addRead(int camera) {
        LONG.getAndAdd(cells, layout.readOffset(camera), 1L);
    }

    public void addNoRead(int camera) {
        LONG.getAndAdd(cells, layout.noReadOffset(camera), 1L);
    }

    /** A volatile read of both counters: what the telemetry thread does. */
    public long total(int camera) {
        return reads(camera) + noReads(camera);
    }

    public long reads(int camera) {
        return (long) LONG.getVolatile(cells, layout.readOffset(camera));
    }

    public long noReads(int camera) {
        return (long) LONG.getVolatile(cells, layout.noReadOffset(camera));
    }
}
