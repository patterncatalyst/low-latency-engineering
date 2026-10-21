package io.patterncatalyst.lowlat.latdist;

import com.google.protobuf.InvalidProtocolBufferException;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.net.StandardProtocolFamily;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Ch1 example: one receive path, three handling policies.
 *
 * <ul>
 *   <li>{@code per-parcel}: handle each parcel on arrival.
 *   <li>{@code batch-32}: hold 32 parcels, then handle them together; one done time per batch.
 *   <li>{@code bimodal-1pct}: per-parcel, but {@code seq % 100 == 0} runs a ~2 ms busy loop.
 * </ul>
 *
 * The common {@code line-consumer-java} has no hook between "received" and "done", so this
 * copies its minimal receive loop (DatagramChannel + Selector, direct buffer).
 */
public final class Latdist {

    private static final int BATCH = 32;
    private static final long SLOW_EVERY = 100;
    private static final int LANES = 8;

    private record Pending(long intendedNs, String barcode) {
    }

    private Latdist() {
    }

    public static void main(String[] args) throws IOException {
        Map<String, String> opt = parse(args);
        String variant = opt.getOrDefault("--variant", "per-parcel");
        if (!List.of("per-parcel", "batch-32", "bimodal-1pct").contains(variant)) {
            throw new IllegalArgumentException("--variant: per-parcel | batch-32 | bimodal-1pct");
        }
        String bind = opt.getOrDefault("--bind", "127.0.0.1:47210");
        long expect = Long.parseLong(opt.getOrDefault("--expect", "0"));
        long idleNs = Long.parseLong(opt.getOrDefault("--idle-timeout-ms", "2000")) * 1_000_000L;
        long slowUs = Long.parseLong(opt.getOrDefault("--slow-us", "2000"));
        Path report = opt.containsKey("--report") ? Path.of(opt.get("--report")) : null;
        boolean batched = variant.equals("batch-32");
        boolean bimodal = variant.equals("bimodal-1pct");
        if (report != null && System.getenv(LatencyRecorder.PROFILE_ENV) == null) {
            throw new IllegalStateException(LatencyRecorder.PROFILE_ENV + " is required with --report");
        }

        long slowIterations = 0;
        long slowMeasuredNs = 0;
        if (bimodal) {
            slowIterations = BusyWork.calibrate(slowUs);
            long t0 = System.nanoTime();
            BusyWork.spin(slowIterations);
            slowMeasuredNs = System.nanoTime() - t0;
            System.out.printf("calibrated slow path: %d iterations = %.1f us%n", slowIterations, slowMeasuredNs / 1e3);
        }

        int colon = bind.lastIndexOf(':');
        LatencyRecorder rec = LatencyRecorder.singleThreaded(
                opt.getOrDefault("--example", "01-latency-distribution"), variant);
        List<Pending> pending = new ArrayList<>(BATCH);
        long highest = -1;
        long dropped = 0;
        long received = 0;
        long reordered = 0;
        long doneCount = 0;
        long firstDone = 0;
        long lastDone = 0;
        long slowCount = 0;
        long lastRx = 0;
        long laneSink = 0;
        String stopped = "idle";
        ByteBuffer buf = ByteBuffer.allocateDirect(2048);

        try (DatagramChannel ch = DatagramChannel.open(StandardProtocolFamily.INET);
                Selector selector = Selector.open()) {
            ch.setOption(StandardSocketOptions.SO_RCVBUF, 4 << 20);
            ch.bind(new InetSocketAddress(bind.substring(0, colon), Integer.parseInt(bind.substring(colon + 1))));
            ch.configureBlocking(false);
            ch.register(selector, SelectionKey.OP_READ);
            System.out.println("latdist-java: variant " + variant + " on " + bind);

            while (true) {
                if (expect > 0 && received + dropped >= expect) {
                    stopped = "expect";
                    break;
                }
                buf.clear();
                SocketAddress src = ch.receive(buf);
                if (src == null) {
                    if (lastRx != 0 && System.nanoTime() - lastRx >= idleNs) {
                        break;
                    }
                    selector.select(key -> { }, 50);
                    continue;
                }
                lastRx = System.nanoTime();
                buf.flip();
                ParcelEvent ev;
                try {
                    ev = ParcelEvent.parseFrom(buf);
                } catch (InvalidProtocolBufferException e) {
                    continue;
                }
                if (ev.getSeq() <= highest) {
                    reordered++;
                    continue;
                }
                long gap = ev.getSeq() - highest - 1;
                dropped += gap;
                highest = ev.getSeq();
                received++;
                if (gap > 0) {
                    rec.addDropped(gap);
                }

                if (batched) {
                    pending.add(new Pending(ev.getIntendedEmitNs(), ev.getBarcode()));
                    if (pending.size() >= BATCH) {
                        for (Pending p : pending) {
                            laneSink += lane(p.barcode());
                        }
                        long done = System.nanoTime(); // one completion time for the whole batch
                        for (Pending p : pending) {
                            rec.record(checked(done - p.intendedNs()));
                        }
                        if (doneCount == 0) {
                            firstDone = done;
                        }
                        lastDone = done;
                        doneCount += pending.size();
                        pending.clear();
                    }
                } else {
                    laneSink += lane(ev.getBarcode());
                    if (bimodal && ev.getSeq() % SLOW_EVERY == 0) {
                        laneSink += BusyWork.spin(slowIterations); // the re-lookup: real CPU work
                        slowCount++;
                    }
                    long done = System.nanoTime();
                    rec.record(checked(done - ev.getIntendedEmitNs()));
                    if (doneCount++ == 0) {
                        firstDone = done;
                    }
                    lastDone = done;
                }
            }
        }
        if (!pending.isEmpty()) { // a partial last batch still gets handled
            for (Pending p : pending) {
                laneSink += lane(p.barcode());
            }
            long done = System.nanoTime();
            for (Pending p : pending) {
                rec.record(checked(done - p.intendedNs()));
            }
            if (doneCount == 0) {
                firstDone = done;
            }
            lastDone = done;
            doneCount += pending.size();
        }

        System.out.printf("received %d dropped %d reordered %d (stopped: %s) [%d]%n",
                received, dropped, reordered, stopped, laneSink & 1);
        long span = lastDone - firstDone;
        String notes = "throughput_mhz=%d; done_span_ns=%d; reordered=%d; JIT not warmed: first parcels included"
                .formatted(doneCount * 1_000_000_000_000L / span, span, reordered);
        if (batched) {
            notes += "; batch=" + BATCH;
        }
        if (bimodal) {
            notes += "; slow_every=%d; slow_parcels=%d; slow_path_us=%.1f; busy loop, not sleep"
                    .formatted(SLOW_EVERY, slowCount, slowMeasuredNs / 1e3);
        }
        rec.printSummary();
        if (report != null) {
            rec.writeReport(report, notes);
        }
    }

    private static long checked(long latencyNs) {
        if (latencyNs < 0) {
            throw new IllegalStateException("negative latency " + latencyNs + " ns: not one CLOCK_MONOTONIC");
        }
        return latencyNs;
    }

    /** The r01 "handle" step: SSCC serial reference (digits 8..16) modulo 8. */
    private static int lane(String sscc) {
        if (sscc.length() != 18) {
            throw new IllegalArgumentException("SSCC-18 must be 18 digits, got '" + sscc + "'");
        }
        long serial = 0;
        for (int i = 8; i < 17; i++) {
            serial = serial * 10 + (sscc.charAt(i) - '0');
        }
        return (int) (serial % LANES);
    }

    private static Map<String, String> parse(String[] args) {
        Map<String, String> m = new java.util.HashMap<>();
        for (int i = 0; i < args.length; i += 2) {
            if (i + 1 >= args.length || !args[i].startsWith("--")) {
                throw new IllegalArgumentException("option " + args[i] + " needs a value");
            }
            m.put(args[i], args[i + 1]);
        }
        return m;
    }
}
