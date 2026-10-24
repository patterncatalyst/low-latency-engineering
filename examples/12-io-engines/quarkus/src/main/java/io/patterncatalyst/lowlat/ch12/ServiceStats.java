package io.patterncatalyst.lowlat.ch12;

import jakarta.enterprise.context.ApplicationScoped;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAccumulator;

/**
 * Exact counters of what the four endpoints did, read by the open-loop client after a run
 * ({@code GET /stats}). They are the evidence behind the chapter's claims: how many threads of each kind
 * served requests, how many requests were in a handler at once, and how many blocked-thread warnings
 * Vert.x logged.
 */
@ApplicationScoped
public class ServiceStats {

    private final AtomicLong requests = new AtomicLong();
    private final AtomicInteger inHandler = new AtomicInteger();
    private final LongAccumulator inHandlerMax = new LongAccumulator(Long::max, 0);
    private final Set<String> eventLoopThreads = ConcurrentHashMap.newKeySet();
    private final Set<String> workerThreads = ConcurrentHashMap.newKeySet();
    private final Set<String> carrierThreads = ConcurrentHashMap.newKeySet();
    private final AtomicInteger onWorkers = new AtomicInteger();
    private final LongAccumulator workerActiveMax = new LongAccumulator(Long::max, 0);
    private final AtomicLong blockedWarnings = new AtomicLong();

    /** A request enters a handler on the current thread. */
    public void begin() {
        requests.incrementAndGet();
        inHandlerMax.accumulate(inHandler.incrementAndGet());
        seen(Thread.currentThread());
    }

    /** The request leaves its handler. */
    public void end() {
        inHandler.decrementAndGet();
    }

    /** A worker-pool handler starts: the simultaneous count of these is the pool's active maximum. */
    public void workerBegin() {
        workerActiveMax.accumulate(onWorkers.incrementAndGet());
    }

    public void workerEnd() {
        onWorkers.decrementAndGet();
    }

    public void blockedThreadWarning() {
        blockedWarnings.incrementAndGet();
    }

    long blockedWarnings() {
        return blockedWarnings.get();
    }

    private void seen(Thread thread) {
        String name = thread.getName();
        if (thread.isVirtual()) {
            // "VirtualThread[#52]/runnable@ForkJoinPool-1-worker-2": the carrier is after the '@'
            String text = thread.toString();
            int at = text.indexOf('@');
            if (at >= 0 && !carrierThreads.contains(text.substring(at + 1))) {
                carrierThreads.add(text.substring(at + 1));
            }
        } else if (name.startsWith("vert.x-eventloop-thread")) {
            if (!eventLoopThreads.contains(name)) {
                eventLoopThreads.add(name);
            }
        } else if (!workerThreads.contains(name)) {
            workerThreads.add(name);
        }
    }

    /** Clears the per-run counters after the warm-up. The blocked-thread count keeps counting. */
    void reset() {
        requests.set(0);
        inHandlerMax.reset();
        workerActiveMax.reset();
        eventLoopThreads.clear();
        workerThreads.clear();
        carrierThreads.clear();
        // blockedWarnings is not reset: it counts the server's whole life, as the log does
    }

    /** {@code name value} lines. */
    String render() {
        return "service_requests " + requests.get() + "\n"
                + "service_in_handler_max " + inHandlerMax.get() + "\n"
                + "worker_active_max " + workerActiveMax.get() + "\n"
                + "worker_threads_seen " + workerThreads.size() + "\n"
                + "event_loop_threads_seen " + eventLoopThreads.size() + "\n"
                + "carrier_threads " + carrierThreads.size() + "\n"
                + "blocked_thread_warnings " + blockedWarnings.get() + "\n";
    }
}
