package io.patterncatalyst.lowlat.offheap;

/**
 * The decide thread of a hand-off that owns a plain thread (the ring and the queue): started with
 * the run's {@link ThreadPlacement}, remembering the error that ended it, and joined on close.
 */
final class DecideThread {

    private volatile Throwable failure;
    private Thread thread;

    void start(ThreadPlacement placement, Runnable body) {
        thread = Thread.ofPlatform()
                .name("decide")
                .uncaughtExceptionHandler((t, error) -> failure = error)
                .unstarted(placement.wrap(body));
        thread.start();
    }

    /** The error that ended the thread, or null while it is healthy. */
    Throwable failure() {
        return failure;
    }

    /** Interrupts the thread when it was started; for a consumer that blocks. */
    void interrupt() {
        if (thread != null) {
            thread.interrupt();
        }
    }

    /** Joins the thread when it was started; the join publishes everything it wrote. */
    void join() {
        if (thread == null) {
            return;
        }
        try {
            thread.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
