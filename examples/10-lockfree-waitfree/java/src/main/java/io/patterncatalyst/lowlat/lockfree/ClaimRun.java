package io.patterncatalyst.lowlat.lockfree;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The claim micro-benchmark: four producers claim 1,000,000 sequence numbers each into a 1M-slot log,
 * one consumer reads it in order, on distinct pinned cores. Each producer times its own claim (not
 * the publish), counts its steps and CAS failures, and marks the claimed sequence in a byte map that
 * only the claimer writes; the map is read after the join, which is the happens-before edge, so the
 * exactly-once check has no race of its own.
 *
 * <p>With {@code --stalled-producer} the producer that claims the middle sequence sleeps 1 ms before it
 * publishes, and the consumer's wait at that sequence is recorded.
 */
final class ClaimRun {

    static final String EXAMPLE = "10-lockfree-waitfree";
    private static final long PAYLOAD_STRIDE = 0x9e3779b97f4a7c15L; // slot payload = seq * stride

    private ClaimRun() {
    }

    static SequenceClaim claimFor(String variant) {
        return switch (variant) {
            case "mutex" -> new SequenceClaim.Locked();
            case "cas-loop" -> new SequenceClaim.CasLoop();
            case "fetch-add" -> new SequenceClaim.FetchAdd();
            default -> throw new IllegalArgumentException("--variant: mutex | cas-loop | fetch-add");
        };
    }

    /** What a run measured, for the tests; the report holds the distribution. */
    record Result(long claims, long steps, long casFailures, long maxRetries, long lostOrDuplicated,
            long payloadMismatches, long consumerMaxWaitNs, long consumerWaitAtStalledNs, long voluntary, long involuntary,
            long producerVoluntaryMax, long producerVoluntaryMin) {
    }

    static void execute(String variant, Args args) throws Exception {
        Path report = args.report();
        if (report != null && !LatencyRecorder.profileConfigured()) {
            throw new IllegalStateException("--report needs " + LatencyRecorder.PROFILE_ENV);
        }
        int producers = (int) args.number("producers", 4);
        long perThread = args.number("claims-per-thread", 1_000_000);
        boolean stalled = args.flag("stalled-producer");
        List<Integer> cpus = args.cpus(producers + 1);
        Placement.Gate gate = new Placement.Gate(producers + 1, args.number("hold-ms", 0));
        // A warm-up pass on the same code, pinned the same way and thrown away: the JIT compiles the claim
        // loops and the log before the measured pass, so a compilation's safepoint is not counted as a
        // context switch of the claim being measured.
        long warmup = args.number("warmup-claims-per-thread", 200_000);
        if (warmup > 0) {
            run(variant, producers, warmup, 1 << 16, false, -1, cpus, new Placement.Gate(producers + 1, 0, false),
                    LatencyRecorder.singleThreaded(EXAMPLE, variant), LatencyRecorder.singleThreaded(EXAMPLE, variant));
        }
        LatencyRecorder merged = LatencyRecorder.singleThreaded(EXAMPLE, variant);
        LatencyRecorder consumerWait = LatencyRecorder.singleThreaded(EXAMPLE, variant);
        Result result = run(variant, producers, perThread, (int) args.number("capacity", 1 << 20), stalled,
                args.number("stalled-seq", producers * perThread / 2), cpus, gate, merged, consumerWait);

        String notes = "claim; producers=" + producers + "; claims_per_thread=" + perThread + "; log_slots="
                + args.number("capacity", 1 << 20) + "; stalled_producer=" + stalled + "; claim time is System.nanoTime around the claim only";
        Map<String, Object> runtime = RuntimeInfo.jvm();
        Map<String, Object> placement = Placement.placement(cpus);
        if (!placement.isEmpty()) {
            runtime.put("placement", placement);
        }
        runtime.put("ctx_switches", Map.of("voluntary", result.voluntary(), "involuntary", result.involuntary()));
        Map<String, Long> counters = new LinkedHashMap<>();
        counters.put("claims", result.claims());
        counters.put("claim_steps", result.steps());
        counters.put("cas_failures", result.casFailures());
        counters.put("cas_max_retries", result.maxRetries());
        counters.put("lost_or_duplicated_claims", result.lostOrDuplicated());
        counters.put("payload_mismatches", result.payloadMismatches());
        counters.put("consumer_max_wait_ns", result.consumerMaxWaitNs());
        counters.put("producer_voluntary_ctx_max", result.producerVoluntaryMax());
        counters.put("producer_voluntary_ctx_min", result.producerVoluntaryMin());
        if (stalled) {
            counters.put("consumer_wait_at_stalled_seq_ns", result.consumerWaitAtStalledNs());
        }
        runtime.put("counters", RuntimeInfo.counters(counters));
        merged.printSummary();
        if (report != null) {
            merged.writeReport(report, notes, null, runtime);
            System.out.println("report: " + report);
            if (consumerWait.histogram().getTotalCount() > 0) {
                consumerWait.printSummary();
                Path waitReport = Report.sibling(report, "-consumer-wait");
                Map<String, Object> waitRuntime = RuntimeInfo.jvm();
                if (!placement.isEmpty()) {
                    waitRuntime.put("placement", placement);
                }
                consumerWait.writeReport(waitReport, notes + "; the consumer's waits at claimed-but-unpublished slots", null, waitRuntime);
                System.out.println("report: " + waitReport);
            }
        }
    }

    /** One run; {@code merged} receives every producer's claim times, {@code consumerWait} the consumer's waits. */
    static Result run(String variant, int producers, long perThread, int capacity, boolean stalled, long stalledSeq,
            List<Integer> cpus, Placement.Gate gate, LatencyRecorder merged, LatencyRecorder consumerWait) throws Exception {
        long total = producers * perThread;
        ClaimLog log = new ClaimLog(claimFor(variant), capacity);
        byte[] claimed = new byte[(int) total]; // claimed[seq] = 1, written by whoever claimed seq
        ClaimStats[] stats = new ClaimStats[producers];
        LatencyRecorder[] claimNs = new LatencyRecorder[producers];
        long[][] ctx = new long[producers][];
        AtomicReference<Throwable> failure = new AtomicReference<>();
        long[] consumer = new long[3]; // payload mismatches, max wait, wait at the stalled sequence: consumer thread, read after join
        List<Thread> threads = new ArrayList<>();
        for (int k = 0; k < producers; k++) {
            stats[k] = new ClaimStats();
            claimNs[k] = LatencyRecorder.singleThreaded(EXAMPLE, variant);
            int index = k;
            threads.add(Thread.ofPlatform().name("producer-" + k).uncaughtExceptionHandler(Placement.recordTo(failure))
                    .unstarted(() -> {
                        try (Placement.Pin _ = gate.workerReady(cpus.get(index), "producer-" + index)) {
                            long[] before = Placement.ctxSwitches();
                            ClaimStats mine = stats[index];
                            LatencyRecorder recorder = claimNs[index];
                            for (long i = 0; i < perThread; i++) {
                                long t0 = System.nanoTime();
                                long seq = log.claim(mine);
                                recorder.record(System.nanoTime() - t0);
                                if (stalled && seq == stalledSeq) {
                                    sleep(Duration.ofMillis(1)); // claimed, not yet published
                                }
                                claimed[(int) seq] = 1;
                                log.publish(seq, seq * PAYLOAD_STRIDE, mine);
                            }
                            long[] after = Placement.ctxSwitches();
                            ctx[index] = new long[] {after[0] - before[0], after[1] - before[1]};
                        }
                    }));
        }
        threads.add(Thread.ofPlatform().name("consumer").uncaughtExceptionHandler(Placement.recordTo(failure))
                .unstarted(() -> {
                    try (Placement.Pin _ = gate.workerReady(cpus.get(producers), "consumer")) {
                        ClaimLog.Reader reader = log.reader();
                        for (long seq = 0; seq < total; seq++) {
                            if (reader.read(seq) != seq * PAYLOAD_STRIDE) {
                                consumer[0]++;
                            }
                            reader.consumed(seq);
                            long waited = reader.waitedNs();
                            if (waited > 0) {
                                consumerWait.record(waited);
                                consumer[1] = Math.max(consumer[1], waited);
                                if (seq == stalledSeq) {
                                    consumer[2] = waited;
                                }
                            }
                        }
                    }
                }));
        threads.forEach(Thread::start);
        gate.release();
        for (Thread thread : threads) {
            thread.join();
        }
        if (failure.get() != null) {
            throw new IllegalStateException("a thread failed", failure.get());
        }

        long claims = 0;
        long steps = 0;
        long casFailures = 0;
        long maxRetries = 0;
        long voluntary = 0;
        long involuntary = 0;
        long voluntaryMax = 0;
        long voluntaryMin = Long.MAX_VALUE;
        for (int k = 0; k < producers; k++) {
            claims += stats[k].claims;
            steps += stats[k].steps;
            casFailures += stats[k].casFailures;
            maxRetries = Math.max(maxRetries, stats[k].maxRetries);
            voluntary += ctx[k][0];
            involuntary += ctx[k][1];
            voluntaryMax = Math.max(voluntaryMax, ctx[k][0]);
            voluntaryMin = Math.min(voluntaryMin, ctx[k][0]);
            merged.histogram().add(claimNs[k].histogram());
        }
        long distinct = 0;
        for (byte b : claimed) {
            distinct += b;
        }
        return new Result(claims, steps, casFailures, maxRetries, total - distinct, consumer[0], consumer[1], consumer[2], voluntary,
                involuntary, voluntaryMax, voluntaryMin);
    }

    private static void sleep(Duration duration) {
        try {
            Thread.sleep(duration);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("interrupted during the stalled producer's sleep", e);
        }
    }
}
