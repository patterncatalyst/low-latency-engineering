package io.patterncatalyst.lowlat.gctails;

import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.Decoder;
import io.patterncatalyst.lowlat.line.LineReceiver;
import io.patterncatalyst.lowlat.line.ParcelHandler;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.Map;

/**
 * Ch6 example: the in-flight tracker on a heap with a large live set and a steady allocation
 * rate, under whichever collector the JVM was started with.
 *
 * <p>The collector, the heap size and the pre-touch are JVM flags chosen by {@code verify.sh};
 * this class does not change with them. It builds the live set, warms the JIT and measures the
 * live set with a forced collection, then binds and records the run (latency, and optionally a
 * flight recording that starts after all of that). The {@code --variant} flag only names the
 * report.
 */
public final class GcTails {

    private GcTails() {
    }

    public static void main(String[] args) throws IOException {
        Options options;
        Config config;
        try {
            options = Options.parse(args);
            Config base = Config.parse(List.of("--bind", "127.0.0.1:47260", "--example", "06-gc-tails",
                    "--variant", "zgc"));
            config = Config.parse(options.rest(), base);
        } catch (Config.HelpRequested e) {
            System.out.print(Options.USAGE);
            return;
        } catch (IllegalArgumentException e) { // includes NumberFormatException
            System.err.println("gctails-java: " + e.getMessage());
            System.err.print(Options.USAGE);
            System.exit(2);
            return;
        }
        if (config.report() != null && !LatencyRecorder.profileConfigured()) {
            System.err.println("gctails-java: --report needs " + LatencyRecorder.PROFILE_ENV);
            System.exit(2);
        }

        Tracker tracker = new Tracker(options.settings());
        tracker.populate();
        warmUp(tracker, options.warmUp());
        long liveSetBytes = liveSetBytes();
        System.out.printf("live set %d bytes: %d manifest entries, %d samples per parcel, %d in flight%n",
                liveSetBytes, tracker.manifestEntries(), tracker.samplesPerParcel(), tracker.inFlightSize());
        if (options.probe()) {
            System.out.println("live_set_bytes=" + liveSetBytes);
            return;
        }

        // The recording starts before the bind: starting JFR takes tens of milliseconds, which
        // must not land on the first parcels.
        Flight.Run<Void> measured = () -> {
            receive(config, options, tracker, liveSetBytes);
            return null;
        };
        if (options.jfr() != null) {
            Flight.during(options.jfr(), measured);
        } else {
            measured.call();
        }
    }

    private static void receive(Config config, Options options, Tracker tracker, long liveSetBytes)
            throws IOException {
        ParcelHandler handler = (event, done) -> {
            tracker.track(event.getBarcode(), event.getSeq(), event.getWeightG());
            done.complete(event);
        };
        try (LineReceiver receiver = new LineReceiver(config)) {
            System.out.println("gctails-java: variant " + config.variant() + " on " + config.bindHost() + ":"
                    + config.bindPort());
            System.out.flush(); // bound: a script reading a redirected stdout waits on this line
            LineReceiver.StopReason reason = receiver.run(handler);
            System.out.printf("received %d dropped %d reordered %d (stopped: %s) [%d]%n", receiver.received(),
                    receiver.dropped(), receiver.reordered(), reason, tracker.sink() & 1);

            LatencyRecorder rec = receiver.recorder();
            rec.printSummary();
            if (config.report() != null) {
                Map<String, Object> runtime = receiver.runtime();
                String notes = ("live_set_bytes=%d; manifest_entries=%d; entry_bytes=%d; samples_per_parcel=%d; "
                        + "alloc_target_bytes_per_s=%d; in_flight=%d; warmup=%d; rcvbuf_granted=%d; "
                        + "jfr=%s; reordered=%d").formatted(liveSetBytes, tracker.manifestEntries(),
                        options.settings().entryBytes(), tracker.samplesPerParcel(),
                        options.settings().allocBytesPerSecond(), options.settings().inFlightParcels(),
                        options.warmUp(), receiver.grantedRcvbuf(), options.jfr() != null ? "in-process" : "off",
                        receiver.reordered());
                rec.writeReport(config.report(), notes, null, runtime);
                if (receiver.windows() != null) { // --window N: the first N parcels and the rest, as in Ch5
                    receiver.windows().writeReports(config.report(), notes, receiver.windowRuntime());
                }
            }
        }
    }

    /**
     * Runs synthetic parcels through the decoder and the tracker, as fast as they go, so the
     * JIT has compiled the per-parcel path (decode and track) before the first real datagram.
     */
    static void warmUp(Tracker tracker, int parcels) {
        ByteBuffer datagram = ByteBuffer.allocateDirect(256);
        Decoder<ParcelEvent> decoder = Decoder.protobuf();
        for (int i = 0; i < parcels; i++) {
            byte[] bytes = ParcelEvent.newBuilder().setSeq(i).setBarcode(Tracker.syntheticBarcode(i))
                    .setWeightG(2000 + (i & 511)).build().toByteArray();
            datagram.clear().put(bytes).flip();
            try {
                ParcelEvent event = decoder.decode(datagram);
                tracker.track(event.getBarcode(), event.getSeq(), event.getWeightG());
            } catch (Decoder.MalformedDatagramException e) {
                throw new IllegalStateException("the warm-up event does not decode", e);
            }
        }
    }

    /**
     * Heap in use after a forced full collection: the live set plus the JVM's own few megabytes.
     * The forced collection is the only way to read it, and it happens before the run starts.
     */
    static long liveSetBytes() {
        MemoryMXBean memory = ManagementFactory.getMemoryMXBean();
        memory.gc();
        return memory.getHeapMemoryUsage().getUsed();
    }
}
