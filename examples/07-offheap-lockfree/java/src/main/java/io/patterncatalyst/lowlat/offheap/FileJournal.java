package io.patterncatalyst.lowlat.offheap;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

/**
 * The audit journal the plain way: one {@link FileChannel#write} per event. Every append is a
 * system call that crosses into the kernel and copies the record into the page cache, which is
 * what the memory-mapped {@link ChronicleJournal} avoids. Fixed 40-byte records (five longs).
 */
final class FileJournal implements Journal {

    private static final int RECORD_BYTES = 40;

    private final FileChannel channel;
    private final ByteBuffer record = ByteBuffer.allocateDirect(RECORD_BYTES);

    FileJournal(Path file) throws IOException {
        this.channel = FileChannel.open(file, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.READ, StandardOpenOption.WRITE);
    }

    @Override
    public void bindToDecideThread() {
        // a channel is not tied to a thread
    }

    @Override
    public void append(ScanView scan, long decidedNs, int lane) {
        record.clear();
        record.putLong(scan.seq()).putLong(scan.intendedNs()).putLong(decidedNs).putLong(scan.serial())
                .putLong(lane);
        record.flip();
        try {
            while (record.hasRemaining()) {
                channel.write(record);
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    @Override
    public Readback readBack() throws IOException {
        ByteBuffer in = ByteBuffer.allocate(RECORD_BYTES);
        channel.position(0);
        long count = 0;
        boolean inOrder = true;
        while (true) {
            in.clear();
            int read = channel.read(in);
            if (read < 0) {
                return new Readback(count, inOrder);
            }
            while (in.hasRemaining() && channel.read(in) >= 0) {
                // a read may return part of a record
            }
            in.flip();
            if (in.remaining() < RECORD_BYTES) {
                return new Readback(count, false);
            }
            inOrder &= in.getLong() == count;
            count++;
        }
    }

    @Override
    public void close() throws IOException {
        channel.close();
    }
}
