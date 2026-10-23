package io.patterncatalyst.lowlat.line;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Makes sure the report is written exactly once, and that a thread which lost the race to write it
 * can wait for the winner to finish before the JVM goes away.
 */
final class ReportGate {

    private final AtomicBoolean claimed = new AtomicBoolean();
    private volatile boolean failed;
    private final CountDownLatch written = new CountDownLatch(1);

    /** Returns true for the first caller only; that caller must call {@link #done()} when finished. */
    boolean claim() {
        return claimed.compareAndSet(false, true);
    }

    /** Marks the claimed write as finished, whether it succeeded or failed. */
    void done() {
        written.countDown();
    }

    /** Marks the claimed write as failed and finished. */
    void failed() {
        failed = true;
        written.countDown();
    }

    /** True when the winner reported a failed write; meaningful after {@link #awaitDone}. */
    boolean hasFailed() {
        return failed;
    }

    /** Waits for the winner's {@link #done()}; returns false when the timeout elapsed first. */
    boolean awaitDone(long timeout, TimeUnit unit) throws InterruptedException {
        return written.await(timeout, unit);
    }
}
