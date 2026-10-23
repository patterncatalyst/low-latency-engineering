package io.patterncatalyst.lowlat.lockfree;

import java.util.concurrent.locks.ReentrantReadWriteLock;
import java.util.concurrent.locks.StampedLock;

/**
 * Parcel-state snapshots for readers that must not delay the writer. The tracker updates a parcel's
 * state at 1 MHz; the diverter and the HMI read it. A snapshot is {@value #WORDS} 64-bit words, the
 * last a checksum of the others, so a reader that gets words from two different updates sees a
 * checksum that does not match.
 *
 * <ul>
 *   <li>{@link ReadWrite}: {@link ReentrantReadWriteLock}. Readers share, the writer excludes them; a
 *       steady stream of readers keeps the writer waiting for the lock.
 *   <li>{@link Stamped}: {@link StampedLock#tryOptimisticRead}, the JDK's seqlock. The reader copies
 *       the words without a lock and keeps the copy only if the stamp is still valid; the writer never
 *       waits for an optimistic reader. The JMM calls the copy of plain fields a data race, which the
 *       validation makes harmless: that is the contract {@code StampedLock} documents.
 * </ul>
 */
sealed interface SnapshotCell {

    int WORDS = 8;

    /** The writer: stores the snapshot. */
    void write(long[] snapshot);

    /** A reader: copies a consistent snapshot into {@code out} and returns the failed optimistic attempts (0 for a lock). */
    int read(long[] out);

    /** Fills {@code out} with the snapshot of update {@code n}: every word a function of {@code n}, the last a checksum. */
    static void of(long n, long[] out) {
        for (int i = 0; i < WORDS - 1; i++) {
            out[i] = n * (2L * i + 3) + i;
        }
        out[WORDS - 1] = checksum(out);
    }

    static long checksum(long[] words) {
        long sum = 0x9e3779b97f4a7c15L;
        for (int i = 0; i < WORDS - 1; i++) {
            sum = (sum ^ words[i]) * 0x100000001b3L;
        }
        return sum;
    }

    static boolean consistent(long[] words) {
        return words[WORDS - 1] == checksum(words);
    }

    final class ReadWrite implements SnapshotCell {
        private final ReentrantReadWriteLock lock = new ReentrantReadWriteLock();
        private final long[] words = new long[WORDS]; // guarded by lock

        ReadWrite() {
            of(0, words);
        }

        @Override
        public void write(long[] snapshot) {
            lock.writeLock().lock();
            try {
                System.arraycopy(snapshot, 0, words, 0, WORDS);
            } finally {
                lock.writeLock().unlock();
            }
        }

        @Override
        public int read(long[] out) {
            lock.readLock().lock();
            try {
                System.arraycopy(words, 0, out, 0, WORDS);
            } finally {
                lock.readLock().unlock();
            }
            return 0;
        }
    }

    final class Stamped implements SnapshotCell {
        private final StampedLock lock = new StampedLock();
        private final long[] words = new long[WORDS]; // written under the write lock, read optimistically

        Stamped() {
            of(0, words);
        }

        @Override
        public void write(long[] snapshot) {
            long stamp = lock.writeLock();
            try {
                System.arraycopy(snapshot, 0, words, 0, WORDS);
            } finally {
                lock.unlockWrite(stamp);
            }
        }

        @Override
        public int read(long[] out) {
            int failed = 0;
            while (true) {
                long stamp = lock.tryOptimisticRead();
                if (stamp != 0) {
                    System.arraycopy(words, 0, out, 0, WORDS);
                    if (lock.validate(stamp)) {
                        return failed;
                    }
                }
                failed++;
                // A writer is in progress or the stamp moved: try again. After a few failures a
                // reader would take the read lock (see the StampedLock javadoc); the writer here
                // updates every microsecond and holds the lock for nanoseconds, so a retry is quicker.
                Thread.onSpinWait();
            }
        }
    }
}
