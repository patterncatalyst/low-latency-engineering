package io.patterncatalyst.lowlat.offheap;

import java.nio.file.Path;
import net.openhft.chronicle.queue.BufferMode;
import net.openhft.chronicle.queue.ChronicleQueue;
import net.openhft.chronicle.queue.ExcerptAppender;
import net.openhft.chronicle.queue.ExcerptTailer;
import net.openhft.chronicle.queue.impl.single.SingleChronicleQueue;
import net.openhft.chronicle.wire.DocumentContext;
import net.openhft.chronicle.wire.Wire;

/**
 * The audit journal on Chronicle Queue (open source, Apache-2.0): a memory-mapped file the
 * appender writes through, so an append is a copy into pages that the operating system writes
 * back later. No system call per record.
 *
 * <p>Only features of the open-source edition are used. {@link BufferMode#None} is its only buffer
 * mode (no asynchronous write buffer), and nothing here needs the commercial pre-toucher,
 * replication or encryption. The open-source queue does not {@code fsync} on append either: a
 * record is durable when the operating system has written the page back, not when {@link #append}
 * returns, so this journal makes no durability claim.
 */
final class ChronicleJournal implements Journal {

    static {
        ChronicleAnalytics.disable(); // before Chronicle builds its first queue
    }

    private final SingleChronicleQueue queue;
    private long bytes;
    private ExcerptAppender appender;

    ChronicleJournal(Path directory) {
        this.queue = ChronicleQueue.singleBuilder(directory)
                .writeBufferMode(BufferMode.None)
                .readBufferMode(BufferMode.None)
                .build();
    }

    @Override
    public void bindToDecideThread() {
        appender = queue.createAppender(); // an appender belongs to the thread that uses it
    }

    @Override
    public void append(ScanView scan, long decidedNs, int lane) {
        try (DocumentContext document = appender.writingDocument()) {
            Wire wire = document.wire();
            wire.write("seq").int64(scan.seq());
            wire.write("intended_ns").int64(scan.intendedNs());
            wire.write("decided_ns").int64(decidedNs);
            wire.write("serial").int64(scan.serial());
            wire.write("lane").int32(lane);
        }
    }

    @Override
    public Readback readBack() {
        ExcerptTailer tailer = queue.createTailer();
        long count = 0;
        boolean inOrder = true;
        while (true) {
            try (DocumentContext document = tailer.readingDocument()) {
                if (!document.isPresent()) {
                    return new Readback(count, inOrder);
                }
                inOrder &= document.wire().read("seq").int64() == count;
                bytes = document.wire().bytes().readLimit();
                count++;
            }
        }
    }

    @Override
    public long bytes() {
        return bytes;
    }

    @Override
    public String settings() {
        return "block_size=" + queue.blockSize() + "; roll_cycle=" + queue.rollCycle();
    }

    @Override
    public void close() {
        queue.close();
    }
}
