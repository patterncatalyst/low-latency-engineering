package io.patterncatalyst.lowlat.jvmcosts;

import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.LineReceiver;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.io.IOException;
import java.lang.management.CompilationMXBean;
import java.lang.management.ManagementFactory;
import java.net.SocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.locks.LockSupport;

/**
 * The {@code warmed} variant's first step: replay synthetic parcels through a throwaway receiver on an
 * ephemeral loopback port, with the same classes the real run uses (receive loop, protobuf decode,
 * tracker, completion, recorder), so the JIT has compiled them before the real socket binds. Then wait
 * for the compiler queue to go quiet. None of it is measured.
 */
final class WarmUp {

    /** What the replay did: parcels sent, handled, and counted missing. */
    record Result(long sent, long handled, long dropped) {
    }

    private static final int BURST = 10;
    private static final long BURST_PAUSE_NS = 500_000; // 10 parcels per 0.5 ms: about 20 kHz, the belt's order of magnitude
    private static final long SEED = 2026;
    private static final int RCVBUF = 4 << 20;
    private static final long IDLE_MS = 500;
    private static final long QUIET_MS = 500;
    private static final long QUIET_LIMIT_MS = 10_000;

    private WarmUp() {
    }

    static Result replay(long parcels) throws IOException, InterruptedException, ExecutionException {
        Config config = new Config("127.0.0.1", 0, RCVBUF, parcels, IDLE_MS, null, "05-jvm-costs", "warm-up");
        TrackerHandler handler = new TrackerHandler(0);
        try (LineReceiver receiver = new LineReceiver(config); ExecutorService sender = Executors.newSingleThreadExecutor()) {
            var sent = sender.submit(() -> send(receiver.localAddress(), parcels));
            receiver.run(handler);
            return new Result(sent.get(), receiver.completion().count(), receiver.dropped());
        }
    }

    private static long send(SocketAddress to, long parcels) throws IOException {
        SyntheticParcels synthetic = new SyntheticParcels(SEED);
        try (DatagramChannel channel = DatagramChannel.open()) {
            channel.connect(to);
            for (long seq = 0; seq < parcels; seq++) {
                long now = System.nanoTime();
                ParcelEvent event = synthetic.next(seq, now, seq * 2);
                channel.write(ByteBuffer.wrap(event.toByteArray()));
                if ((seq + 1) % BURST == 0) {
                    LockSupport.parkNanos(BURST_PAUSE_NS);
                }
            }
        }
        return parcels;
    }

    /**
     * Blocks until the JIT's cumulative compile time stops growing for {@value #QUIET_MS} ms (at most
     * {@value #QUIET_LIMIT_MS} ms) and returns the compile time spent in total, in ms. The tier-4 (C2)
     * compiles queued by the replay finish here, not in the first window of the run.
     */
    static long awaitCompilerQuiet() throws InterruptedException {
        CompilationMXBean jit = ManagementFactory.getCompilationMXBean();
        long waitedMs = 0;
        long quietMs = 0;
        long last = jit.getTotalCompilationTime();
        while (quietMs < QUIET_MS && waitedMs < QUIET_LIMIT_MS) {
            Thread.sleep(50);
            waitedMs += 50;
            long now = jit.getTotalCompilationTime();
            quietMs = now == last ? quietMs + 50 : 0;
            last = now;
        }
        return last;
    }
}
