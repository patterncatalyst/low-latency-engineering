package io.patterncatalyst.lowlat.eliminating;

import java.util.concurrent.atomic.AtomicLongArray;

/**
 * Per-camera counters for the five scan-tunnel cameras: each camera has a read count and a no-read count, written
 * by that camera's thread only, sampled by a telemetry thread.
 *
 * <p>One {@link AtomicLongArray}; camera {@code c}'s counters sit at index {@code c * stride} and
 * {@code c * stride + 1}. {@code stride} is the layout: 2 longs (16 bytes) puts neighbouring cameras on one cache
 * line (false sharing); 8 (64 bytes) gives each camera a line; 16 (128 bytes) a line pair. The padding is not
 * idiomatic Java: it is a measured latency construct, and the JDK's own answer for a contended sum is
 * {@link java.util.concurrent.atomic.LongAdder}, which stripes and pads internally (a different shape: one
 * total, not one value per camera). {@code @Contended} would be the in-JDK spelling of the padding, but it is JDK-internal
 * outside java.base, so the layout is explicit instead.
 *
 * <p>Java does not control where an array sits relative to a cache line, so a stride of 8 longs keeps cameras at
 * least 64 bytes apart (never the same line) and 16 keeps them at least 128 bytes apart (never the same line pair).
 */
public final class CameraCounters {

    public static final int CAMERAS = 5;
    /** Longs per camera for the layouts of the chapter. */
    public static final int ADJACENT = 2;
    public static final int LINE_PADDED = 8;
    public static final int PAIR_PADDED = 16;

    private final AtomicLongArray cells;
    private final int stride;

    public CameraCounters(int stride) {
        if (stride < 2) {
            throw new IllegalArgumentException("a camera needs two counters");
        }
        this.stride = stride;
        this.cells = new AtomicLongArray(CAMERAS * stride + PAIR_PADDED); // trailing pad: no camera shares a line with the array's neighbour
    }

    public int stride() {
        return stride;
    }

    /** Index of camera {@code c}'s read counter. */
    public int readIndex(int camera) {
        return camera * stride;
    }

    /** Single writer: a plain read and a release store, no read-modify-write (a plain store on x86). */
    public void bumpRead(int camera) {
        int i = camera * stride;
        cells.setRelease(i, cells.getPlain(i) + 1);
    }

    public void bumpNoRead(int camera) {
        int i = camera * stride + 1;
        cells.setRelease(i, cells.getPlain(i) + 1);
    }

    /** The same increment as an atomic read-modify-write ({@code lock xadd} on x86), for the contrast run. */
    public void addRead(int camera) {
        cells.getAndAdd(camera * stride, 1L);
    }

    public void addNoRead(int camera) {
        cells.getAndAdd(camera * stride + 1, 1L);
    }

    /** A volatile read of both counters: what the telemetry thread does. */
    public long total(int camera) {
        return cells.get(camera * stride) + cells.get(camera * stride + 1);
    }

    public long noReads(int camera) {
        return cells.get(camera * stride + 1);
    }
}
