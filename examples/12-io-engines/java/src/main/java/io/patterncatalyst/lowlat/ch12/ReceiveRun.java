package io.patterncatalyst.lowlat.ch12;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.StandardProtocolFamily;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.ClosedChannelException;
import java.nio.channels.DatagramChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.ToLongFunction;
import java.util.concurrent.atomic.AtomicReferenceArray;

/**
 * The receive path in plain JDK: four tunnel cameras (four simulator instances, flat wire, one UDP
 * port each), three ways to wait for a datagram.
 *
 * <ul>
 *   <li>{@code selector}: one platform thread, a NIO {@link Selector} over four non-blocking
 *       {@link DatagramChannel}s (readiness; epoll underneath).
 *   <li>{@code virtual-thread-blocking}: four virtual threads, each in a blocking
 *       {@code DatagramChannel.receive}. The JDK parks a virtual thread on its poller, which is epoll
 *       underneath. One carrier thread, pinned.
 *   <li>{@code thread-per-core}: four pinned platform threads, each with its own socket
 *       ({@code SO_REUSEPORT} set) and a blocking {@code receive}.
 * </ul>
 *
 * The JDK has no io_uring, so there is no completion variant here: that is the divergence from C++.
 * The whole measured loop is warmed first: the same receive code runs a pass of its own threads and sockets,
 * fed in-process, and its result is thrown away.
 */
final class ReceiveRun {

    static final String EXAMPLE = "12-io-engines";
    static final int CAMERAS = 4;
    private static final long WARMUP_INTERVAL_NS = 40_000;

    private ReceiveRun() {
    }

    /** One thread's counters. Each receive thread allocates its own, so two threads are unlikely to share a line (Java has no
     * {@code alignas}; separate allocations from separate thread-local buffers are likely, not guaranteed, to sit on separate lines). */
    static final class Counters {
        long datagrams;
        long malformed;
        long parcels;
        long receives;
        long selects;
        long startNs;
        final long[] lanes = new long[Wire.LANES];
        final LatencyRecorder latency = LatencyRecorder.singleThreaded(EXAMPLE, "pass");
        long lost;
    }

    /** All threads arrive, then read the clock: the recorded skew is the spread after the last arrival. */
    static final class SpinStart {
        private final AtomicInteger arrived = new AtomicInteger();
        private final int threads;

        SpinStart(int threads) {
            this.threads = threads;
        }

        long arriveAndGo() {
            if (Thread.currentThread().isVirtual()) {
                // One carrier runs all four virtual threads. Spinning, or yielding in a loop, would keep the
                // pool's local queue busy and starve the threads still waiting to be resumed; the carrier runs
                // them one after the other in microseconds, which is the skew this records.
                return System.nanoTime();
            }
            arrived.incrementAndGet();
            while (arrived.get() < threads) {
                Thread.onSpinWait();
            }
            return System.nanoTime();
        }
    }

    /** Busy-waits {@code ns}: the stand-in for the decide work this example does not build (same as the C++ lane). */
    static void work(long ns) {
        if (ns <= 0) {
            return;
        }
        long until = System.nanoTime() + ns;
        while (System.nanoTime() < until) {
            Thread.onSpinWait();
        }
    }

    /** What one pass produced. */
    record Pass(List<Counters> counters, long lost, int rcvbuf) {
        long sum(ToLongFunction<Counters> field) {
            return counters.stream().mapToLong(field).sum();
        }

        long skewNs() {
            long first = counters.stream().mapToLong(c -> c.startNs).min().orElse(0);
            long last = counters.stream().mapToLong(c -> c.startNs).max().orElse(0);
            return last - first;
        }
    }

    static void execute(String variant, Args args) throws Exception {
        if (!List.of("selector", "virtual-thread-blocking", "thread-per-core").contains(variant)) {
            throw new IllegalArgumentException("--variant: selector | virtual-thread-blocking | thread-per-core");
        }
        Path report = args.report();
        if (report != null && !LatencyRecorder.profileConfigured()) {
            throw new IllegalStateException("--report needs " + LatencyRecorder.PROFILE_ENV);
        }
        int threads = threadsFor(variant);
        List<Integer> cpus = args.cpus(variant.equals("thread-per-core") ? CAMERAS : 1);
        long decideNs = args.number("decide-ns", 0);
        int idleMs = (int) args.number("idle-ms", 1500);

        long warmup = args.number("warmup-parcels-per-camera", 6_000);
        if (warmup > 0) {
            DatagramChannel[] channels = open(new int[CAMERAS]);
            try {
                Thread feeder = Thread.ofPlatform().name("warmup-feeder").start(() -> feed(channels, warmup));
                pass(variant, channels, warmup, cpus, new Placement.Gate(threads, 0, false), decideNs, 500);
                feeder.join();
            } finally {
                close(channels);
            }
        }

        int basePort = (int) args.number("base-port", 47320);
        int[] ports = new int[CAMERAS];
        for (int i = 0; i < CAMERAS; i++) {
            ports[i] = basePort + i;
        }
        long expect = args.number("expect", 50_000);
        DatagramChannel[] channels = open(ports);
        Pass pass;
        try {
            pass = pass(variant, channels, expect, cpus, new Placement.Gate(threads, args.number("hold-ms", 0)), decideNs, idleMs);
        } finally {
            close(channels);
        }

        LatencyRecorder merged = LatencyRecorder.singleThreaded(EXAMPLE, variant);
        pass.counters().forEach(c -> merged.histogram().add(c.latency.histogram()));
        merged.addDropped(pass.lost());
        System.out.printf("receive: %s parcels %d dropped %d datagrams %d receive calls %d select calls %d start skew %d ns%n", variant,
                pass.sum(c -> c.parcels), pass.lost(), pass.sum(c -> c.datagrams), pass.sum(c -> c.receives), pass.sum(c -> c.selects),
                pass.skewNs());
        merged.printSummary();
        if (report == null) {
            return;
        }
        Map<String, Object> runtime = new TreeMap<>();
        if (cpus.stream().allMatch(c -> c >= 0)) {
            runtime.put("placement", Placement.placement(cpus));
        }
        Map<String, Long> counters = new TreeMap<>();
        counters.put("parcels", pass.sum(c -> c.parcels));
        counters.put("datagrams", pass.sum(c -> c.datagrams));
        counters.put("malformed", pass.sum(c -> c.malformed));
        counters.put("dropped", pass.lost());
        counters.put("receive_calls", pass.sum(c -> c.receives));
        counters.put("select_calls", pass.sum(c -> c.selects));
        counters.put("start_skew_ns", pass.skewNs());
        counters.put("rcvbuf_granted", (long) pass.rcvbuf());
        counters.put("threads", (long) threads);
        counters.put("warmup_parcels_per_camera", warmup);
        runtime.put("counters", RuntimeInfo.counters(counters));
        String notes = "receive; cameras=" + CAMERAS + "; expect_per_camera=" + expect + "; flat wire; variant=" + variant
                + "; threads=" + threads + "; idle_ms=" + idleMs + "; decide_ns=" + decideNs + "; warmup_parcels_per_camera=" + warmup
                + "; the JDK has no io_uring; call counts are Java-level (receive and select), not system calls";
        merged.writeReport(report, notes, null, runtime);
        System.out.println("report: " + report);
    }

    static int threadsFor(String variant) {
        return variant.equals("thread-per-core") ? CAMERAS : variant.equals("selector") ? 1 : CAMERAS;
    }

    /** Four bound channels, SO_REUSEPORT where the platform has it, a 4 MiB receive buffer requested. Port 0 picks one. */
    static DatagramChannel[] open(int[] ports) throws IOException {
        DatagramChannel[] channels = new DatagramChannel[ports.length];
        try {
            for (int i = 0; i < ports.length; i++) {
                DatagramChannel ch = DatagramChannel.open(StandardProtocolFamily.INET);
                channels[i] = ch;
                if (ch.supportedOptions().contains(StandardSocketOptions.SO_REUSEPORT)) {
                    ch.setOption(StandardSocketOptions.SO_REUSEPORT, true);
                }
                ch.setOption(StandardSocketOptions.SO_RCVBUF, 4 * 1024 * 1024);
                ch.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), ports[i]));
            }
        } catch (IOException | RuntimeException e) {
            close(channels);
            throw e;
        }
        return channels;
    }

    static void close(DatagramChannel[] channels) {
        for (DatagramChannel ch : channels) {
            if (ch != null) {
                try {
                    ch.close();
                } catch (IOException e) {
                    // closing a socket that is already closed is not an error here
                }
            }
        }
    }

    /** Sends {@code perCamera} parcels to each channel's address, round-robin, one every {@link #WARMUP_INTERVAL_NS}. */
    static void feed(DatagramChannel[] targets, long perCamera) {
        try (DatagramChannel out = DatagramChannel.open(StandardProtocolFamily.INET)) {
            ByteBuffer buf = Wire.newBuffer();
            InetSocketAddress[] to = new InetSocketAddress[targets.length];
            for (int i = 0; i < targets.length; i++) {
                to[i] = (InetSocketAddress) targets[i].getLocalAddress();
            }
            long t0 = System.nanoTime();
            long n = 0;
            for (long seq = 0; seq < perCamera; seq++) {
                for (InetSocketAddress dest : to) {
                    long due = t0 + n++ * WARMUP_INTERVAL_NS;
                    while (System.nanoTime() < due) {
                        Thread.onSpinWait();
                    }
                    out.send(Wire.encode(buf, seq, System.nanoTime(), "003400001234567890"), dest);
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    @SuppressWarnings("try") // the Pin is held for its scope; closing it is what releases the affinity
    static Pass pass(String variant, DatagramChannel[] channels, long expect, List<Integer> cpus, Placement.Gate gate, long decideNs,
            int idleMs) throws Exception {
        int threads = threadsFor(variant);
        SpinStart spin = new SpinStart(threads);
        AtomicReferenceArray<Counters> counters = new AtomicReferenceArray<>(threads);
        // Each tracker is allocated by the thread that owns it, before its gate, as its Counters is; the join publishes it.
        SeqTracker[] trackers = new SeqTracker[CAMERAS];
        List<Throwable> failures = Collections.synchronizedList(new ArrayList<>());
        List<Thread> pool = new ArrayList<>();
        int rcvbuf = channels[0].getOption(StandardSocketOptions.SO_RCVBUF);

        switch (variant) {
            case "selector" -> pool.add(Thread.ofPlatform().name("selector").unstarted(guard(failures, () -> {
                Counters c = new Counters();
                counters.set(0, c);
                for (int i = 0; i < CAMERAS; i++) {
                    trackers[i] = new SeqTracker(expect);
                }
                try (Placement.Pin pin = gate.workerReady(cpus.get(0), "selector")) {
                    c.startNs = spin.arriveAndGo();
                    selectLoop(channels, trackers, c, decideNs, idleMs);
                }
            })));
            case "virtual-thread-blocking" -> {
                for (int i = 0; i < CAMERAS; i++) {
                    int camera = i;
                    pool.add(Thread.ofVirtual().name("camera-" + i).unstarted(guard(failures, () -> {
                        Counters c = new Counters();
                        counters.set(camera, c);
                        trackers[camera] = new SeqTracker(expect);
                        // The pin lands on the carrier thread this virtual thread is mounted on.
                        try (Placement.Pin pin = gate.workerReady(cpus.get(0), "vt-camera-" + camera)) {
                            c.startNs = spin.arriveAndGo();
                            blockingLoop(channels[camera], trackers[camera], c, decideNs);
                        }
                    })));
                }
            }
            default -> {
                for (int i = 0; i < CAMERAS; i++) {
                    int camera = i;
                    pool.add(Thread.ofPlatform().name("core-" + i).unstarted(guard(failures, () -> {
                        Counters c = new Counters();
                        counters.set(camera, c);
                        trackers[camera] = new SeqTracker(expect);
                        try (Placement.Pin pin = gate.workerReady(cpus.get(camera), "core-" + camera)) {
                            c.startNs = spin.arriveAndGo();
                            blockingLoop(channels[camera], trackers[camera], c, decideNs);
                        }
                    })));
                }
            }
        }
        pool.forEach(Thread::start);
        gate.release();
        watch(pool, counters, channels, idleMs);
        for (Thread t : pool) {
            t.join();
        }
        if (!failures.isEmpty()) {
            throw new IllegalStateException("a receive thread failed", failures.get(0));
        }
        List<Counters> all = new ArrayList<>();
        for (int i = 0; i < threads; i++) {
            all.add(counters.get(i));
        }
        long lost = 0;
        for (SeqTracker t : trackers) {
            lost += t.lost();
        }
        return new Pass(all, lost, rcvbuf);
    }

    private static Runnable guard(List<Throwable> failures, ThrowingRunnable body) {
        return () -> {
            try {
                body.run();
            } catch (ClosedChannelException e) {
                // the watchdog closed the socket after the cameras went quiet: the run is over
            } catch (Throwable t) {
                System.err.println("thread " + Thread.currentThread().getName() + " failed: " + t);
                failures.add(t);
            }
        };
    }

    @FunctionalInterface
    private interface ThrowingRunnable {
        void run() throws Exception;
    }

    /**
     * Waits for the threads to finish. When the cameras go quiet (no new datagram for {@code idleMs}) it closes the
     * sockets, which ends the blocking receives with a ClosedChannelException.
     */
    private static void watch(List<Thread> pool, AtomicReferenceArray<Counters> counters, DatagramChannel[] channels, int idleMs)
            throws InterruptedException {
        long lastTotal = -1;
        long lastChange = System.nanoTime();
        while (pool.stream().anyMatch(Thread::isAlive)) {
            Thread.sleep(50);
            long total = 0;
            for (int i = 0; i < counters.length(); i++) {
                Counters c = counters.get(i);
                if (c != null) {
                    total += readOpaque(c);
                }
            }
            long now = System.nanoTime();
            if (total != lastTotal) {
                lastTotal = total;
                lastChange = now;
            } else if (total > 0 && now - lastChange > idleMs * 1_000_000L) {
                close(channels);
            }
        }
    }

    private static final VarHandle DATAGRAMS = fieldHandle();

    private static VarHandle fieldHandle() {
        try {
            return MethodHandles.lookup().findVarHandle(Counters.class, "datagrams", long.class);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private static long readOpaque(Counters c) {
        return (long) DATAGRAMS.getOpaque(c);
    }

    private static void selectLoop(DatagramChannel[] channels, SeqTracker[] trackers, Counters c, long decideNs, int idleMs)
            throws IOException {
        ByteBuffer buf = Wire.newBuffer();
        try (Selector selector = Selector.open()) {
            for (int i = 0; i < channels.length; i++) {
                channels[i].configureBlocking(false);
                channels[i].register(selector, SelectionKey.OP_READ, i);
            }
            long lastRx = 0;
            while (!allComplete(trackers)) {
                long before = c.datagrams;
                selector.select(key -> {
                    int camera = (Integer) key.attachment();
                    try {
                        // Readiness says "something is there": take everything until the socket says "nothing".
                        while (true) {
                            buf.clear();
                            c.receives++;
                            if (channels[camera].receive(buf) == null) {
                                break;
                            }
                            buf.flip();
                            handle(buf, trackers[camera], c, decideNs);
                        }
                    } catch (IOException e) {
                        throw new UncheckedIOException(e);
                    }
                }, 100);
                c.selects++;
                if (c.datagrams != before) {
                    lastRx = System.nanoTime();
                } else if (lastRx != 0 && System.nanoTime() - lastRx > idleMs * 1_000_000L) {
                    return;
                }
            }
        }
    }

    private static void blockingLoop(DatagramChannel channel, SeqTracker tracker, Counters c, long decideNs) throws IOException {
        ByteBuffer buf = Wire.newBuffer();
        while (!tracker.complete()) {
            buf.clear();
            c.receives++;
            if (channel.receive(buf) == null) {
                continue;
            }
            buf.flip();
            handle(buf, tracker, c, decideNs);
        }
    }

    private static boolean allComplete(SeqTracker[] trackers) {
        for (SeqTracker t : trackers) {
            if (!t.complete()) {
                return false;
            }
        }
        return true;
    }

    /** Decode, sequence-check, decide (lane lookup and modelled work), record latency from the intended emit time. */
    static void handle(ByteBuffer buf, SeqTracker tracker, Counters c, long decideNs) {
        c.datagrams++;
        if (!Wire.valid(buf)) {
            c.malformed++;
            return;
        }
        if (!tracker.observe(Wire.seq(buf))) {
            return;
        }
        c.lanes[Wire.lane(buf)]++;
        work(decideNs);
        long latency = System.nanoTime() - Wire.intendedEmitNs(buf);
        if (latency < 0) {
            throw new IllegalStateException("negative latency " + latency + " ns: producer and consumer are not on one CLOCK_MONOTONIC");
        }
        c.latency.record(latency);
        c.parcels++;
    }

}
