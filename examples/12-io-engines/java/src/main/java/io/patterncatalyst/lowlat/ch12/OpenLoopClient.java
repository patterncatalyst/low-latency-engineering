package io.patterncatalyst.lowlat.ch12;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Path;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAccumulator;
import java.util.concurrent.locks.LockSupport;

/**
 * The open-loop HTTP/1.1 client for the sort-plan service (plain JDK: virtual threads and
 * {@link HttpClient}).
 *
 * <p>Request {@code i} is due at {@code start + i / rate} whatever happened to the earlier ones: the
 * dispatcher never waits for a response, so a slow service cannot slow the arrivals (the coordinated
 * omission rule, Ch3). Latency is measured from the intended time, not from when the request left, so
 * a late dispatch or a queue in front of the service counts. The dispatcher's own lateness is recorded
 * as a second report (variant {@code client-lateness}), and the number of requests it started more
 * than a millisecond late is a counter: a run in which the client waited is visible in its own report.
 *
 * <p>HTTP/1.1 carries one request per connection at a time, and the JDK client opens a connection
 * for every request that finds none idle (its pool is unbounded: {@code jdk.httpclient.connectionPoolSize}
 * defaults to 0), so no request waits for a connection. {@code max_in_flight} is the client's evidence.
 * The whole measured loop is warmed first: the same schedule runs for {@code --warmup-seconds} against
 * the same service and is thrown away.
 *
 * <p>HTTP/1.1 on loopback is a harness here, not a transport recommendation (Part 6).
 */
final class OpenLoopClient {

    private static final long LATE_START_NS = 1_000_000;

    private OpenLoopClient() {
    }

    /** What one run measured. */
    record Result(LatencyRecorder latency, LatencyRecorder lateness, long sent, long completed, long errors, long maxInFlight,
            long lateStarts) {
    }

    static void execute(Args args) throws Exception {
        String base = args.text("base-url", "http://127.0.0.1:8080");
        String variant = args.text("variant", "");
        String path = args.text("path", "/plan/" + variant + "/");
        long rate = args.number("rate", 10_000);
        long seconds = args.number("seconds", 5);
        long warmupSeconds = args.number("warmup-seconds", 3);
        long poolThreads = args.number("pool", 16);
        double serviceTimeMs = args.number("service-time-ms", 2);
        Path report = args.report();
        if (variant.isEmpty()) {
            throw new IllegalArgumentException("--variant is required (event-loop | worker-pool | virtual-thread | blocking-on-event-loop)");
        }
        if (report != null && !LatencyRecorder.profileConfigured()) {
            throw new IllegalStateException("--report needs " + LatencyRecorder.PROFILE_ENV);
        }
        double littles = rate * serviceTimeMs / 1000.0;
        System.out.printf("client: %s at %d Hz for %d s (warm-up %d s); Little's law: %d Hz x %.0f ms = %.1f in flight, worker pool %d%n",
                variant, rate, seconds, warmupSeconds, rate, serviceTimeMs, littles, poolThreads);

        HttpClient client = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).connectTimeout(Duration.ofSeconds(5)).build();
        try {
            if (warmupSeconds > 0) {
                run(client, base + path, variant, rate, warmupSeconds);
                post(client, base + "/stats/reset");
            }
            Result r = run(client, base + path, variant, rate, seconds);
            String stats = get(client, base + "/stats");
            r.latency().printSummary();
            r.lateness().printSummary();
            System.out.printf("client: sent %d completed %d errors %d max in flight %d (Little's law %.1f) late starts over 1 ms %d%n", r.sent(),
                    r.completed(), r.errors(), r.maxInFlight(), littles, r.lateStarts());
            System.out.println("service: " + stats.replace('\n', ' ').strip());
            if (report == null) {
                return;
            }
            Map<String, Long> counters = new TreeMap<>();
            counters.put("sent", r.sent());
            counters.put("completed", r.completed());
            counters.put("errors", r.errors());
            counters.put("max_in_flight", r.maxInFlight());
            counters.put("late_starts_over_1ms", r.lateStarts());
            counters.put("worker_pool_threads", poolThreads);
            counters.putAll(parseStats(stats));
            Map<String, Object> runtime = new LinkedHashMap<>();
            runtime.put("counters", RuntimeInfo.counters(counters));
            Map<String, Object> model = new LinkedHashMap<>();
            model.put("lambda_hz", rate);
            model.put("service_time_ms", serviceTimeMs);
            model.put("littles_law_in_flight", littles);
            model.put("worker_pool_threads", poolThreads);
            String notes = "service; variant=" + variant + "; open loop; rate_hz=" + rate + "; seconds=" + seconds + "; warmup_seconds="
                    + warmupSeconds + "; HTTP/1.1 on loopback; latency from the intended send time";
            r.latency().writeReport(report, notes, model, runtime);
            r.lateness().writeReport(sibling(report, "-lateness"), notes + "; dispatcher lateness (start of dispatch minus intended time)",
                    null, null);
            System.out.println("report: " + report);
        } finally {
            client.close();
        }
    }

    static Path sibling(Path report, String suffix) {
        String name = report.getFileName().toString();
        int dot = name.lastIndexOf('.');
        String stem = dot < 0 ? name : name.substring(0, dot);
        return report.resolveSibling(stem + suffix + (dot < 0 ? "" : name.substring(dot)));
    }

    /** Dispatches {@code rate x seconds} requests on the open-loop schedule and waits for every response. */
    static Result run(HttpClient client, String url, String variant, long rate, long seconds) throws Exception {
        long total = rate * seconds;
        LatencyRecorder latency = LatencyRecorder.concurrent(ReceiveRun.EXAMPLE, variant);
        LatencyRecorder lateness = LatencyRecorder.singleThreaded(ReceiveRun.EXAMPLE, "client-lateness");
        AtomicInteger inFlight = new AtomicInteger();
        LongAccumulator maxInFlight = new LongAccumulator(Long::max, 0);
        AtomicLong completed = new AtomicLong();
        AtomicLong errors = new AtomicLong();
        long lateStarts = 0;
        long start = System.nanoTime() + 200_000_000L;
        try (ExecutorService vts = Executors.newVirtualThreadPerTaskExecutor()) {
            for (long i = 0; i < total; i++) {
                long due = OpenLoopSchedule.intendedSendNanos(start, i, rate);
                sleepUntil(due);
                long late = Math.max(0, System.nanoTime() - due);
                lateness.record(late);
                if (late > LATE_START_NS) {
                    lateStarts++;
                }
                String uri = url + sscc(i);
                vts.execute(() -> {
                    maxInFlight.accumulate(inFlight.incrementAndGet());
                    try {
                        HttpResponse<Void> response = client.send(HttpRequest.newBuilder(URI.create(uri)).GET().build(),
                                HttpResponse.BodyHandlers.discarding());
                        long ns = System.nanoTime() - due; // from the intended time, not from when the request left
                        if (response.statusCode() == 200) {
                            latency.record(ns);
                            completed.incrementAndGet();
                        } else {
                            errors.incrementAndGet();
                        }
                    } catch (IOException e) {
                        errors.incrementAndGet();
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        errors.incrementAndGet();
                    } finally {
                        inFlight.decrementAndGet();
                    }
                });
            }
        } // closing the executor waits for every request
        latency.addDropped(errors.get());
        return new Result(latency, lateness, total, completed.get(), errors.get(), maxInFlight.get(), lateStarts);
    }

    /** Parks until shortly before {@code due}, then spins: a late wake-up costs the schedule nothing. */
    static void sleepUntil(long due) {
        long remaining;
        while ((remaining = due - System.nanoTime()) > 0) {
            if (remaining > 200_000) {
                LockSupport.parkNanos(remaining - 150_000);
            } else {
                Thread.onSpinWait();
            }
        }
    }

    /** A valid SSCC-18 for parcel {@code i}: the serial counts up, the check digit is not verified by the service. */
    static String sscc(long i) {
        return String.format("00340000%09d0", i % 1_000_000_000L);
    }

    /** The service's {@code name value} lines as counters (non-numeric values are ignored). */
    static Map<String, Long> parseStats(String text) {
        Map<String, Long> out = new TreeMap<>();
        for (String line : text.split("\n")) {
            String[] kv = line.strip().split("\\s+");
            if (kv.length == 2) {
                try {
                    out.put(kv[0], Long.parseLong(kv[1]));
                } catch (NumberFormatException e) {
                    // a line that is not a counter
                }
            }
        }
        return out;
    }

    private static String get(HttpClient client, String url) throws IOException, InterruptedException {
        return client.send(HttpRequest.newBuilder(URI.create(url)).GET().build(), HttpResponse.BodyHandlers.ofString()).body();
    }

    private static void post(HttpClient client, String url) throws IOException, InterruptedException {
        client.send(HttpRequest.newBuilder(URI.create(url)).POST(HttpRequest.BodyPublishers.noBody()).build(),
                HttpResponse.BodyHandlers.discarding());
    }
}
