package io.patterncatalyst.lowlat.ch11;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/** Wiring skeleton: runs {@code n} tasks, each on its own virtual thread, and counts completions. */
public final class ParkedTasks {

    private ParkedTasks() {}

    public static int runOnVirtualThreads(int n) throws InterruptedException {
        AtomicInteger done = new AtomicInteger();
        CountDownLatch finished = new CountDownLatch(n);
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            for (int i = 0; i < n; i++) {
                executor.execute(() -> {
                    done.incrementAndGet();
                    finished.countDown();
                });
            }
            finished.await();
        }
        return done.get();
    }
}
