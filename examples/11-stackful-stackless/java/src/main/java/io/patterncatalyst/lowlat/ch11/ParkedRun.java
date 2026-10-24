package io.patterncatalyst.lowlat.ch11;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.locks.LockSupport;

/**
 * Memory per waiting task. {@code tasks} threads each wait on one shared deadline ({@code waitMs} after the
 * start gate opens): platform threads or virtual threads, same task body. Samples are wake lateness. Counters
 * are the start handshake, the heap after a forced collection (what a parked virtual thread keeps alive; the
 * virtual thread's stack is a heap object) and the process's RSS, address space, page tables and the system's
 * kernel stacks (what a parked platform thread costs).
 */
final class ParkedRun {

    private ParkedRun() {
    }

    static Run execute(Run.Kind kind, int tasks, long waitMs, boolean announce, long holdMs) throws InterruptedException {
        CountDownLatch armed = new CountDownLatch(tasks);
        CountDownLatch go = new CountDownLatch(1);
        CountDownLatch woken = new CountDownLatch(tasks);
        long[] woke = new long[tasks];
        long[] deadline = new long[1]; // written before go.countDown(), read after go.await()
        Placement.Gate gate = new Placement.Gate(0, holdMs, announce);
        gate.release(); // no pinned workers here; this prints the markers verify.sh waits for
        Procinfo.Snapshot before = Procinfo.snapshot(true);
        Thread[] threads = new Thread[tasks];
        Thread.Builder builder = kind.builder();
        try {
            for (int i = 0; i < tasks; i++) {
                int index = i;
                threads[i] = builder.unstarted(() -> {
                    armed.countDown();
                    awaitUninterruptibly(go);
                    long remaining;
                    while ((remaining = deadline[0] - System.nanoTime()) > 0) {
                        LockSupport.parkNanos(remaining);
                    }
                    woke[index] = System.nanoTime();
                    woken.countDown();
                });
                threads[i].start();
            }
        } catch (OutOfMemoryError e) {
            deadline[0] = System.nanoTime();
            go.countDown();
            throw new IllegalStateException("could not start thread " + (tasks - (int) armed.getCount() + 1) + " of " + tasks + ": " + e.getMessage(), e);
        }
        armed.await(); // the handshake: every task is running and about to wait
        long when = System.nanoTime() + waitMs * 1_000_000L;
        deadline[0] = when;
        go.countDown();
        Thread.sleep(waitMs / 2);
        Procinfo.Snapshot parked = Procinfo.snapshot(true);
        woken.await();
        for (Thread t : threads) {
            t.join();
        }
        long[] lateness = new long[tasks];
        for (int i = 0; i < tasks; i++) {
            lateness[i] = Math.max(1, woke[i] - when);
        }
        Map<String, Long> counters = new HashMap<>();
        counters.put("tasks", (long) tasks);
        counters.put("tasks_armed", (long) tasks - armed.getCount());
        memory(counters, before, parked, tasks);
        String notes = "parked; model=" + kind.variant + "; wait_ms=" + waitMs + "; heap figures are taken after System.gc()";
        return Run.of(lateness, counters, List.of(), null, notes);
    }

    private static void awaitUninterruptibly(CountDownLatch latch) {
        boolean interrupted = false;
        while (true) {
            try {
                latch.await();
                break;
            } catch (InterruptedException e) {
                interrupted = true;
            }
        }
        if (interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    static void memory(Map<String, Long> counters, Procinfo.Snapshot before, Procinfo.Snapshot parked, int tasks) {
        long rss = Math.max(0, parked.rssKib() - before.rssKib());
        long vsize = Math.max(0, parked.vmSizeKib() - before.vmSizeKib());
        long pte = Math.max(0, parked.pageTablesKib() - before.pageTablesKib());
        long kstack = Math.max(0, parked.kernelStackKib() - before.kernelStackKib());
        long heap = Math.max(0, parked.heapUsedBytes() - before.heapUsedBytes());
        counters.put("rss_before_kib", before.rssKib());
        counters.put("rss_parked_kib", parked.rssKib());
        counters.put("rss_delta_kib", rss);
        counters.put("rss_bytes_per_task", rss * 1024 / tasks);
        counters.put("vm_size_delta_kib", vsize);
        counters.put("vm_size_bytes_per_task", vsize * 1024 / tasks);
        counters.put("page_tables_delta_kib", pte);
        counters.put("kernel_stack_delta_kib", kstack);
        counters.put("rss_page_tables_kernel_stack_bytes_per_task", (rss + pte + kstack) * 1024 / tasks);
        counters.put("heap_delta_bytes", heap);
        counters.put("heap_bytes_per_task", heap / tasks);
    }
}
