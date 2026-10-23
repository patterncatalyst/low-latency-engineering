package io.patterncatalyst.lowlat.offheap;

import java.io.IOException;

/**
 * The audit journal: one record per scan event, appended by the decide thread after the divert
 * command has gone out. Both implementations write the same five numbers, so the append cost is
 * the only difference between them.
 */
public interface Journal extends AutoCloseable {

    /** What reading the journal back found. */
    record Readback(long count, boolean inOrder) {
    }

    /** Bytes of journal the appended records occupy (the file's length for a plain file). Call after {@link #readBack}. */
    long bytes();

    /** The journal's own settings as {@code key=value} pairs for the report notes; empty if it has none. */
    String settings();

    /** Called on the decide thread before the first {@link #append}; some journals bind a writer to it. */
    void bindToDecideThread();

    /** Appends one record. Decide thread only. */
    void append(ScanView scan, long decidedNs, int lane);

    /**
     * Reads every record back from the start and checks that the sequence numbers run 0, 1, 2, ...
     * Call it after the decide thread has finished.
     */
    Readback readBack() throws IOException;

    @Override
    void close() throws IOException;
}
