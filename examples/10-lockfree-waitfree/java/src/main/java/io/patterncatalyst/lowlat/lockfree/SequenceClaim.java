package io.patterncatalyst.lowlat.lockfree;

import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Three ways to hand out the next sequence number of a multi-producer log. The progress guarantee
 * belongs to the operation, not to the structure:
 *
 * <ul>
 *   <li>{@link Locked}: blocking. A producer that holds the lock and is descheduled stops every other.
 *   <li>{@link CasLoop}: lock-free. Some producer always completes, but one can lose the race again and again.
 *   <li>{@link FetchAdd}: {@code getAndIncrement} is one {@code lock xadd} on x86-64, so every producer
 *       finishes in one step. On an LL/SC machine (some AArch64 and RISC-V cores) the same call is a
 *       retry loop in the JIT, so "wait-free" depends on the platform.
 * </ul>
 *
 * The sequence is a 64-bit, strictly increasing {@code long}: a number is never reused, so there is no
 * ABA to defend against, and the collector does the reclamation that hazard pointers or epochs do in
 * C++.
 */
sealed interface SequenceClaim {

    /** The next unique sequence number. */
    long claim(ClaimStats stats);

    /** Blocking: a {@link ReentrantLock} around a plain counter. */
    final class Locked implements SequenceClaim {
        private final ReentrantLock lock = new ReentrantLock();
        private long next; // guarded by lock

        @Override
        public long claim(ClaimStats stats) {
            lock.lock();
            try {
                stats.claims++;
                stats.steps++;
                return next++;
            } finally {
                lock.unlock();
            }
        }
    }

    /** Lock-free: {@link AtomicLong#compareAndSet} in a loop. */
    final class CasLoop implements SequenceClaim {
        private final AtomicLong next = new AtomicLong();

        @Override
        public long claim(ClaimStats stats) {
            stats.claims++;
            long retries = 0;
            long seen;
            do {
                seen = next.get();
                stats.steps++;
                if (next.compareAndSet(seen, seen + 1)) {
                    break;
                }
                stats.casFailures++;
                retries++;
            } while (true);
            stats.maxRetries = Math.max(stats.maxRetries, retries);
            return seen;
        }
    }

    /** Wait-free on x86-64: {@link AtomicLong#getAndIncrement}. */
    final class FetchAdd implements SequenceClaim {
        private final AtomicLong next = new AtomicLong();

        @Override
        public long claim(ClaimStats stats) {
            stats.claims++;
            stats.steps++;
            return next.getAndIncrement();
        }
    }
}
