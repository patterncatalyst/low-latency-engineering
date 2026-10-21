package io.patterncatalyst.lowlat.ch02;

import com.google.protobuf.InvalidProtocolBufferException;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.StandardProtocolFamily;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.channels.Selector;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.LockSupport;
import java.util.random.RandomGenerator;
import java.util.random.RandomGeneratorFactory;

/**
 * Little's Law on the parcel line (L = lambda * W), Java edition: see {@code ../../README.md}.
 *
 * <p>A single-server consumer whose handling takes a variable (exponential) service time. W is
 * recorded per parcel (done minus intended emit time) with the measurement kit; L is sampled at a
 * fixed interval as parcels due by the schedule minus parcels done. The time-average L, lambda
 * and the mean W go into the report's {@code model} block, with the prediction lambda * W.
 */
public final class LittlesConsumer {

    private static final long NS = 1_000_000_000L;

    private record Options(int port, long rateHz, int durationS, double serviceMeanUs, long sampleUs,
                           long seed, double budgetMs, double beltMps, Path report, String example,
                           String variant) {

        static Options parse(String[] args) {
            Map<String, String> kv = new HashMap<>();
            for (int i = 0; i < args.length; i += 2) {
                if (i + 1 >= args.length) {
                    throw new IllegalArgumentException(args[i] + " needs a value");
                }
                kv.put(args[i], args[i + 1]);
            }
            Options o = new Options(
                    Integer.parseInt(kv.getOrDefault("--port", "47221")),
                    Long.parseLong(kv.getOrDefault("--rate", "1000")),
                    Integer.parseInt(kv.getOrDefault("--duration", "10")),
                    Double.parseDouble(kv.getOrDefault("--service-mean-us", "600")),
                    Long.parseLong(kv.getOrDefault("--sample-us", "997")),
                    Long.parseLong(kv.getOrDefault("--seed", "7")),
                    Double.parseDouble(kv.getOrDefault("--budget-ms", "480")),
                    Double.parseDouble(kv.getOrDefault("--belt-mps", "2.5")),
                    kv.containsKey("--report") ? Path.of(kv.get("--report")) : null,
                    kv.getOrDefault("--example", "02-littles-amdahl"),
                    kv.getOrDefault("--variant", "littles-law"));
            for (String key : kv.keySet()) {
                if (!List.of("--port", "--rate", "--duration", "--service-mean-us", "--sample-us",
                        "--seed", "--budget-ms", "--belt-mps", "--report", "--example", "--variant")
                        .contains(key)) {
                    throw new IllegalArgumentException("unknown option " + key);
                }
            }
            return o;
        }
    }

    /** What the sampler thread hands back through join(). */
    private static final class Sampled {
        long sumInSystem;
        long samples;
        long maxInSystem;
    }

    private LittlesConsumer() {
    }

    /**
     * Counts the parcels in the system at fixed intervals: due by the schedule minus done. The
     * interval is 997 us, deliberately not a divisor of the 1 ms arrival period: a sampler locked
     * to a deterministic arrival stream always sees the same phase (just after an arrival) and
     * over-counts by about half a parcel. The sample is taken at the instant the clock is read,
     * not at the nominal tick.
     */
    private static Sampled sample(AtomicLong done, long t0Ns, Options o) {
        Sampled s = new Sampled();
        long endNs = t0Ns + o.durationS() * NS;
        for (long tick = t0Ns; tick < endNs; tick += o.sampleUs() * 1000) {
            long wait = tick - System.nanoTime();
            if (wait > 0) {
                LockSupport.parkNanos(wait);
            }
            long now = System.nanoTime();
            long inSystem = Model.arrivalsBy(now, t0Ns, o.rateHz()) - done.get();
            s.sumInSystem += inSystem;
            s.maxInSystem = Math.max(s.maxInSystem, inSystem);
            s.samples++;
        }
        return s;
    }

    /** Busy-wait for the service time: stands in for CPU work whose length varies per parcel. */
    private static void serve(long serviceNs) {
        long until = System.nanoTime() + serviceNs;
        while (System.nanoTime() < until) {
            Thread.onSpinWait();
        }
    }

    public static void main(String[] args) throws Exception {
        Options o;
        try {
            o = Options.parse(args);
        } catch (IllegalArgumentException e) {
            System.err.println("littles-consumer-java: " + e.getMessage());
            System.exit(2);
            return;
        }
        if (o.report() != null && System.getenv(LatencyRecorder.PROFILE_ENV) == null) {
            System.err.println("littles-consumer-java: --report needs " + LatencyRecorder.PROFILE_ENV);
            System.exit(2);
        }
        long expect = o.rateHz() * o.durationS();
        LatencyRecorder latency = LatencyRecorder.singleThreaded(o.example(), o.variant());
        RandomGenerator rng = RandomGeneratorFactory.<RandomGenerator>of("Xoshiro256PlusPlus").create(o.seed());
        double capUs = 10.0 * o.serviceMeanUs();
        AtomicLong done = new AtomicLong();
        Sampled[] sampled = new Sampled[1];
        Thread sampler = null;
        long received = 0;
        long dropped = 0;
        long nextSeq = 0;
        long lastRxNs = 0;
        double wSumNs = 0; // input to the model block only, never reported as a latency

        System.out.printf("littles-consumer-java: 127.0.0.1:%d, lambda=%d /s, service mean %.0f us "
                + "(offered utilisation %.2f)%n", o.port(), o.rateHz(), o.serviceMeanUs(),
                o.rateHz() * o.serviceMeanUs() / 1e6);

        try (DatagramChannel ch = DatagramChannel.open(StandardProtocolFamily.INET);
             Selector selector = Selector.open()) {
            ch.setOption(StandardSocketOptions.SO_RCVBUF, 4 * 1024 * 1024);
            ch.bind(new InetSocketAddress("127.0.0.1", o.port()));
            ch.configureBlocking(false);
            ch.register(selector, java.nio.channels.SelectionKey.OP_READ);
            ByteBuffer buf = ByteBuffer.allocateDirect(2048);

            while (received + dropped < expect) {
                buf.clear();
                if (ch.receive(buf) == null) {
                    if (lastRxNs != 0 && System.nanoTime() - lastRxNs > 2 * NS) {
                        break; // idle: the run is over
                    }
                    selector.select(key -> { }, 100);
                    continue;
                }
                buf.flip();
                ParcelEvent ev;
                try {
                    ev = ParcelEvent.parseFrom(buf);
                } catch (InvalidProtocolBufferException e) {
                    continue;
                }
                long seq = ev.getSeq();
                if (seq < nextSeq) {
                    continue; // reordered
                }
                dropped += seq - nextSeq;
                nextSeq = seq + 1;
                if (sampler == null) {
                    // Parcel `seq` is due at t0 + seq / lambda, so t0 follows from any first parcel.
                    long t0 = ev.getIntendedEmitNs() - seq * NS / o.rateHz();
                    Options opts = o;
                    sampler = Thread.ofPlatform().name("sampler").start(() -> sampled[0] = sample(done, t0, opts));
                }
                serve((long) (Math.min(rng.nextExponential() * o.serviceMeanUs(), capUs) * 1000.0));
                long doneNs = System.nanoTime();
                lastRxNs = doneNs;
                done.incrementAndGet();
                received++;
                long wNs = doneNs - ev.getIntendedEmitNs();
                if (wNs < 0) {
                    throw new IllegalStateException("negative latency: producer and consumer not on one clock");
                }
                latency.record(wNs);
                wSumNs += wNs;
            }
        }
        latency.addDropped(dropped);
        if (sampler != null) {
            sampler.join(); // ends at t0 + duration; join also publishes `sampled`
        }
        if (received == 0 || sampled[0] == null || sampled[0].samples == 0) {
            System.err.println("littles-consumer-java: no parcels received");
            System.exit(1);
        }

        // --- the model block: the only place a mean appears ---------------------------------
        Sampled s = sampled[0];
        double lambda = o.rateHz();
        double wMeanS = wSumNs / received / 1e9;
        double lSampled = (double) s.sumInSystem / s.samples;
        double lPredicted = Model.littlesL(lambda, wMeanS);
        double relErr = (lSampled - lPredicted) / lPredicted;
        double inFlight = Model.littlesL(lambda, o.budgetMs() / 1000.0);
        double beltM = o.beltMps() * o.budgetMs() / 1000.0;

        Map<String, Object> model = new LinkedHashMap<>();
        model.put("law", "Little: L = lambda * W");
        model.put("lambda_per_s", lambda);
        model.put("L_sampled_time_average", lSampled);
        model.put("W_mean_seconds_modelling_input", wMeanS);
        model.put("predicted_L", lPredicted);
        model.put("relative_error", relErr);
        model.put("samples", s.samples);
        model.put("sample_interval_us", o.sampleUs());
        model.put("max_in_system", s.maxInSystem);
        model.put("service_mean_us", o.serviceMeanUs());
        model.put("offered_utilisation", lambda * o.serviceMeanUs() / 1e6);
        model.put("warehouse", Map.of("scan_to_divert_budget_ms", o.budgetMs(), "belt_mps", o.beltMps(),
                "belt_metres_in_budget", beltM, "in_flight_parcels", inFlight));

        latency.printSummary();
        System.out.printf("model: lambda=%.0f/s  L(sampled)=%.3f  W-bar(model input)=%.3f ms  "
                + "predicted L=lambda*W=%.3f  error=%+.2f%%  (samples=%d, max in system=%d)%n",
                lambda, lSampled, wMeanS * 1e3, lPredicted, relErr * 100.0, s.samples, s.maxInSystem);
        System.out.printf("warehouse: %.0f ms scan-to-divert x %.0f/s = %.0f parcels in flight on %.2f m of belt "
                + "at %s m/s%n", o.budgetMs(), lambda, inFlight, beltM, o.beltMps());
        if (o.report() != null) {
            latency.writeReport(o.report(), "received=%d dropped=%d seed=%d; W recorded per parcel as done - "
                    + "intended emit time; JIT not warmed".formatted(received, dropped, o.seed()));
            ModelReport.addModel(o.report(), model);
            System.out.println("report: " + o.report());
        }
    }
}
