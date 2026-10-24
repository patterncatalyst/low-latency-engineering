package io.patterncatalyst.lowlat.ch11;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Hand-off cost: two threads pass a turn back and forth through a pair of {@link SynchronousQueue}s, platform
 * threads on two pinned cores or virtual threads sharing one carrier (start the JVM with
 * {@code -Djdk.virtualThreadScheduler.parallelism=1}; the flag lands in build.flags). A sample is the time of
 * one batch divided by the batch size.
 */
final class PingPongRun {

    private static final Object TURN = new Object();
    private static final Object STOP = new Object();

    private PingPongRun() {
    }

    static Run execute(Run.Kind kind, long rounds, int batch, long warmupBatches, List<Integer> cpus, long holdMs, boolean announce)
            throws InterruptedException {
        if (batch <= 0 || rounds <= 0 || rounds % batch != 0) {
            throw new IllegalArgumentException("--rounds must be a positive multiple of --batch");
        }
        // Platform threads: one CPU each. Virtual threads: both run on the one carrier, so one pin.
        int cpuA = cpus.isEmpty() ? -1 : cpus.get(0);
        int cpuB = kind == Run.Kind.VIRTUAL ? cpuA : cpus.size() < 2 ? -1 : cpus.get(1);
        if (kind == Run.Kind.PLATFORM && cpuB < 0) {
            cpuA = -1;
        }
        final int pinA = cpuA;
        final int pinB = cpuB;
        Placement.Gate gate = new Placement.Gate(2, holdMs, announce);
        SynchronousQueue<Object> ping = new SynchronousQueue<>();
        SynchronousQueue<Object> pong = new SynchronousQueue<>();
        long[] slot = new long[16]; // slot[8] is the payload; neighbours on other lines are untouched
        long[] samples = new long[(int) (rounds / batch)];
        long[] acc = new long[1];
        long[] served = new long[1];
        long[][] ctxA = new long[1][];
        long[][] ctxB = new long[1][];
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread.Builder builder = kind.builder();

        Thread b = builder.unstarted(() -> {
            try (Placement.Pin _ = gate.workerReady(pinB, "pong")) {
                long[] c0 = Placement.ctxSwitches();
                while (ping.take() != STOP) {
                    slot[8] += 1;
                    served[0]++;
                    pong.put(TURN);
                }
                ctxB[0] = delta(c0);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } catch (Throwable t) {
                failure.compareAndSet(null, t);
            }
        });
        Thread a = builder.unstarted(() -> {
            try (Placement.Pin _ = gate.workerReady(pinA, "ping")) {
                long[] c0 = Placement.ctxSwitches();
                for (long w = 0; w < warmupBatches; w++) {
                    for (int j = 0; j < batch; j++) {
                        acc[0] += turn(slot, ping, pong, j);
                    }
                }
                int at = 0;
                for (long done = 0; done < rounds; done += batch) {
                    long t0 = System.nanoTime();
                    for (int j = 0; j < batch; j++) {
                        acc[0] += turn(slot, ping, pong, j);
                    }
                    samples[at++] = Math.max(1, (System.nanoTime() - t0) / batch);
                }
                ctxA[0] = delta(c0);
                ping.put(STOP);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } catch (Throwable t) {
                failure.compareAndSet(null, t);
                b.interrupt();
            }
        });
        b.start();
        a.start();
        gate.release();
        a.join();
        b.join();
        if (failure.get() != null) {
            throw new IllegalStateException("a ping-pong thread failed", failure.get());
        }
        long expected = (warmupBatches + rounds / batch) * ((long) batch * (batch + 1) / 2);
        Map<String, Long> counters = new HashMap<>();
        counters.put("round_trips", rounds);
        counters.put("round_trips_served", served[0]);
        counters.put("warmup_round_trips", warmupBatches * batch);
        counters.put("payload_mismatch", acc[0] == expected ? 0L : 1L);
        counters.put("start_skew_ns", gate.startSkewNs());
        counters.put("ctx_voluntary_a", ctxA[0][0]);
        counters.put("ctx_involuntary_a", ctxA[0][1]);
        long voluntary = ctxA[0][0];
        long involuntary = ctxA[0][1];
        if (kind == Run.Kind.PLATFORM) {
            counters.put("ctx_voluntary_b", ctxB[0][0]);
            counters.put("ctx_involuntary_b", ctxB[0][1]);
            voluntary += ctxB[0][0];
            involuntary += ctxB[0][1];
        } // virtual threads: both ran on one carrier, whose switches thread A's window already holds
        List<Integer> placed = new ArrayList<>();
        for (int cpu : new int[] {pinA, pinB}) {
            if (cpu >= 0 && !placed.contains(cpu)) {
                placed.add(cpu);
            }
        }
        String notes = "pingpong; model=" + kind.variant + " (SynchronousQueue); rounds=" + rounds + "; batch=" + batch
                + "; sample=batch time / batch" + (kind == Run.Kind.VIRTUAL ? "; one carrier thread (virtualThreadScheduler.parallelism=1)" : "");
        return Run.of(samples, counters, placed, new long[] {voluntary, involuntary}, notes);
    }

    private static long turn(long[] slot, SynchronousQueue<Object> ping, SynchronousQueue<Object> pong, int j) throws InterruptedException {
        slot[8] = j;
        ping.put(TURN);
        pong.take();
        return slot[8];
    }

    private static long[] delta(long[] start) {
        long[] now = Placement.ctxSwitches();
        return new long[] {now[0] - start[0], now[1] - start[1]};
    }
}
