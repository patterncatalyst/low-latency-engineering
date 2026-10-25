package io.patterncatalyst.lowlat.ch12;

import jakarta.enterprise.context.ApplicationScoped;
import java.lang.management.ManagementFactory;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.LongAccumulator;
import java.util.concurrent.atomic.LongAdder;
import jdk.management.VirtualThreadSchedulerMXBean;

/**
 * Exact counters of what the four endpoints did, read by the open-loop client after a run
 * ({@code GET /stats}). They are the evidence behind the chapter's claims: how many threads of each kind
 * served requests, how many requests were in a handler at once, and how many blocked-thread warnings
 * Vert.x logged. {@code carrier_threads} is the size of the virtual-thread scheduler's carrier pool, read from
 * {@link VirtualThreadSchedulerMXBean} when the stats are rendered, and 0 until a virtual thread has served a
 * request since the last reset.
 */
@ApplicationScoped
public class ServiceStats {

    private static final VirtualThreadSchedulerMXBean SCHEDULER =
            ManagementFactory.getPlatformMXBean(VirtualThreadSchedulerMXBean.class);

    private final LongAdder requests = new LongAdder();
    private final LongAdder virtualRequests = new LongAdder();
    private final AtomicInteger inHandler = new AtomicInteger();
    private final LongAccumulator inHandlerMax = new LongAccumulator(Long::max, 0);
    private final Set<String> eventLoopThreads = ConcurrentHashMap.newKeySet();
    private final Set<String> workerThreads = ConcurrentHashMap.newKeySet();
    private final AtomicInteger onWorkers = new AtomicInteger();
    private final LongAccumulator workerActiveMax = new LongAccumulator(Long::max, 0);
    private final LongAdder blockedWarnings = new LongAdder();
    private volatile long blockedAtReset;

    /** A request enters a handler on the current thread. */
    public void begin() {
        requests.increment();
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
        blockedWarnings.increment();
    }

    long blockedWarnings() {
        return blockedWarnings.sum();
    }

    private void seen(Thread thread) {
        if (thread.isVirtual()) {
            virtualRequests.increment();
        } else if (thread.getName().startsWith("vert.x-eventloop-thread")) {
            eventLoopThreads.add(thread.getName());
        } else {
            workerThreads.add(thread.getName());
        }
    }

    /** Clears the per-run counters after the warm-up. The blocked-thread count keeps counting. */
    void reset() {
        requests.reset();
        virtualRequests.reset();
        inHandlerMax.reset();
        workerActiveMax.reset();
        eventLoopThreads.clear();
        workerThreads.clear();
        // blockedWarnings is not reset: it counts the server's whole life, as the log does. The count at this moment is kept,
        // so that the warnings of the measured run alone (the ones after the warm-up) can be read.
        blockedAtReset = blockedWarnings.sum();
    }

    /** {@code name value} lines. */
    String render() {
        long blocked = blockedWarnings.sum();
        return "service_requests " + requests.sum() + "\n"
                + "service_in_handler_max " + inHandlerMax.get() + "\n"
                + "worker_active_max " + workerActiveMax.get() + "\n"
                + "worker_threads_seen " + workerThreads.size() + "\n"
                + "event_loop_threads_seen " + eventLoopThreads.size() + "\n"
                + "carrier_threads " + (virtualRequests.sum() > 0 ? SCHEDULER.getPoolSize() : 0) + "\n"
                + "blocked_thread_warnings " + blocked + "\n"
                + "blocked_thread_warnings_in_run " + (blocked - blockedAtReset) + "\n";
    }
}
