package io.patterncatalyst.lowlat.ch02;

import io.patterncatalyst.lowlat.line.Completion;
import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.LineReceiver;
import io.patterncatalyst.lowlat.line.ParcelHandler;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
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
 *
 * <p>The common {@link LineReceiver} binds, parses, tracks gaps and records W; this class supplies
 * the {@link ParcelHandler} (the service time, the sampler) and the model block.
 */
public final class LittlesConsumer {

    private static final long NS = 1_000_000_000L;

    private record Options(int port, long rateHz, int durationS, double serviceMeanUs, long sampleUs,
                           long seed, double budgetMs, double beltMps, Path report, String example,
                           String variant) {

        private static final Set<String> KEYS = Set.of("--port", "--rate", "--duration", "--service-mean-us",
                "--sample-us", "--seed", "--budget-ms", "--belt-mps", "--report", "--example", "--variant");

        static Options parse(String[] args) {
            Map<String, String> kv = Cli.pairs(args, KEYS);
            return new Options(
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
        }
    }

    /** What the sampler thread hands back through its FutureTask. */
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

    /**
     * The per-parcel hook: serve for an exponential time, then complete. Starts the sampler on the
     * first parcel; the receive thread owns everything but {@code done}, which the sampler reads.
     */
    private static final class Service implements ParcelHandler {
        private final Options o;
        private final RandomGenerator rng;
        private final double capUs;
        private final AtomicLong done = new AtomicLong();
        private FutureTask<Sampled> sampler;
        private double wSumNs; // input to the model block only, never reported as a latency

        Service(Options o) {
            this.o = o;
            this.rng = RandomGeneratorFactory.of("Xoshiro256PlusPlus").create(o.seed());
            this.capUs = 10.0 * o.serviceMeanUs();
        }

        @Override
        public void onParcel(ParcelEvent event, Completion completion) {
            if (sampler == null) {
                // Parcel `seq` is due at t0 + seq / lambda, so t0 follows from any first parcel.
                long t0 = event.getIntendedEmitNs() - event.getSeq() * NS / o.rateHz();
                sampler = new FutureTask<>(() -> sample(done, t0, o));
                Thread.ofPlatform().name("sampler").start(sampler);
            }
            serve((long) (Math.min(rng.nextExponential() * o.serviceMeanUs(), capUs) * 1000.0));
            long doneNs = System.nanoTime();
            done.incrementAndGet();
            completion.complete(event.getIntendedEmitNs(), doneNs);
            wSumNs += doneNs - event.getIntendedEmitNs();
        }

        /** Waits for the sampler (it ends at t0 + duration); null when no parcel arrived. */
        Sampled sampled() throws InterruptedException, ExecutionException {
            return sampler == null ? null : sampler.get();
        }
    }

    public static void main(String[] args) throws IOException, InterruptedException, ExecutionException {
        Options o;
        try {
            o = Options.parse(args);
        } catch (IllegalArgumentException e) {
            System.err.println("littles-consumer-java: " + e.getMessage());
            System.exit(2);
            return;
        }
        if (o.report() != null && !LatencyRecorder.profileConfigured()) {
            System.err.println("littles-consumer-java: --report needs " + LatencyRecorder.PROFILE_ENV);
            System.exit(2);
        }
        Config config = new Config("127.0.0.1", o.port(), 4 << 20, o.rateHz() * o.durationS(), 2000, null,
                o.example(), o.variant());
        Service service = new Service(o);

        System.out.printf("littles-consumer-java: 127.0.0.1:%d, lambda=%d /s, service mean %.0f us "
                + "(offered utilisation %.2f)%n", o.port(), o.rateHz(), o.serviceMeanUs(),
                o.rateHz() * o.serviceMeanUs() / 1e6);

        LatencyRecorder latency;
        long received;
        long dropped;
        Sampled s;
        try (LineReceiver receiver = new LineReceiver(config)) {
            receiver.run(service); // returns on the expected count or 2 s idle
            latency = receiver.recorder();
            received = receiver.received();
            dropped = receiver.dropped();
            s = service.sampled(); // the sampler's get() is also the happens-before edge to its result
        }
        if (received == 0 || s == null || s.samples == 0) {
            System.err.println("littles-consumer-java: no parcels received");
            System.exit(1);
        }

        // --- the model block: the only place a mean appears ---------------------------------
        double lambda = o.rateHz();
        double wMeanS = service.wSumNs / received / 1e9;
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
            latency.writeReport(o.report(), ("received=%d dropped=%d seed=%d; W recorded per parcel as done - "
                    + "intended emit time; JIT not warmed").formatted(received, dropped, o.seed()), model);
            System.out.println("report: " + o.report());
        }
    }
}
