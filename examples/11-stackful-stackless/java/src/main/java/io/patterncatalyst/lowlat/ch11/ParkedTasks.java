package io.patterncatalyst.lowlat.ch11;

import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/** Wiring skeleton: runs {@code n} tasks, each on its own virtual thread, and counts completions. */
public final class ParkedTasks {

    private ParkedTasks() {}

    public static int runOnVirtualThreads(int n) {
        AtomicInteger done = new AtomicInteger();
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            for (int i = 0; i < n; i++) {
                executor.execute(done::incrementAndGet);
            }
        } // close() waits for every submitted task
        return done.get();
    }
}
