package io.patterncatalyst.lowlat.eliminating;

import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.Decoder;
import io.patterncatalyst.lowlat.line.EventHandler;
import io.patterncatalyst.lowlat.line.EventReceiver;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import net.openhft.affinity.AffinityLock;

/**
 * The line consumer of Ch9: the common receive loop ({@link EventReceiver}) with the hub parcel tracker as its
 * handler. The tracker is preloaded with {@code --preload} parcels (the hub: 1,000,000) before the socket is
 * bound; each parcel the simulator sends is tracked and the oldest preloaded parcel is retired, so the table
 * stays at hub size. {@code --variant node-map} or {@code flat-map}; the report variant is {@code line-node-map}
 * or {@code line-flat-map}. The report's {@code runtime.alloc_bytes_per_parcel} is what the receive thread
 * allocated per parcel, protobuf decode included (the decode dominates).
 */
final class LineRun {

    static final String EXAMPLE = "09-eliminating-work";
    static final int DEFAULT_PORT = 47290;
    private static final String USAGE = """
            usage: Main consume --variant node-map|flat-map [--preload N] [--cpu CPU] [--bind HOST:PORT] [--rcvbuf BYTES]
                                [--expect N] [--idle-timeout-ms MS] [--report FILE]
              Options as line-consumer-java (consumers/README.md). Default bind 127.0.0.1:47290.
            """;

    private LineRun() {
    }

    static int run(List<String> args) throws IOException {
        int preload = 1_000_000;
        int cpu = -1;
        List<String> rest = new ArrayList<>();
        try {
            for (int i = 0; i < args.size(); i++) {
                switch (args.get(i)) {
                    case "--preload" -> preload = Integer.parseInt(args.get(++i));
                    case "--cpu" -> cpu = Integer.parseInt(args.get(++i));
                    default -> rest.add(args.get(i));
                }
            }
        } catch (RuntimeException e) {
            System.err.println("consume: " + e.getMessage());
            System.err.print(USAGE);
            return 2;
        }
        Config base = new Config("127.0.0.1", DEFAULT_PORT, 4 << 20, 0, 2000, null, EXAMPLE, "flat-map");
        Config parsed;
        try {
            parsed = Config.parse(rest, base);
        } catch (Config.HelpRequested e) {
            System.out.print(USAGE);
            return 0;
        } catch (IllegalArgumentException e) {
            System.err.println("consume: " + e.getMessage());
            System.err.print(USAGE);
            return 2;
        }
        String tracker = parsed.variant();
        if (!tracker.equals("node-map") && !tracker.equals("flat-map")) {
            System.err.println("consume: --variant must be node-map or flat-map, got " + tracker);
            return 2;
        }
        if (parsed.report() != null && !LatencyRecorder.profileConfigured()) {
            System.err.println("consume: --report needs " + LatencyRecorder.PROFILE_ENV
                    + " (run scripts/profile.sh --out FILE): a number without a profile is not publishable");
            return 2;
        }
        Config config = new Config(parsed.bindHost(), parsed.bindPort(), parsed.rcvbuf(), parsed.expect(),
                parsed.idleTimeoutMs(), parsed.report(), parsed.example(), "line-" + tracker, parsed.window());

        AffinityLock lock = cpu >= 0 ? Placement.acquire(cpu) : null; // null: unpinned
        try (lock) {
            int capacity = preload + preload / 16 + 1_024;
            Tracker table = tracker.equals("node-map") ? new NodeMapTracker(capacity) : FlatMapTracker.withColumns(capacity);
            Keys preloaded = Keys.make(preload, 2026);
            Scan scan = new Scan();
            for (int i = 0; i < preload; i++) {
                table.track(scan.of(preloaded, i));
            }
            System.out.println("preloaded " + table.size() + " parcels");
            return receive(config, table, preloaded, cpu);
        }
    }

    private static int receive(Config config, Tracker tracker, Keys preloaded, int cpu) throws IOException {
        Scan scan = new Scan(); // reused: the handler allocates nothing of its own
        int[] retired = {0};
        EventHandler<ParcelEvent> handler = (event, done) -> {
            scan.barcode = event.getBarcode();
            scan.seq = event.getSeq();
            scan.tick = event.getEncoderTick();
            scan.weightG = event.getWeightG();
            scan.lengthMm = (short) event.getDims().getLengthMm();
            scan.widthMm = (short) event.getDims().getWidthMm();
            scan.heightMm = (short) event.getDims().getHeightMm();
            scan.confidencePermille = (short) event.getScanConfidencePermille();
            tracker.track(scan);
            if (retired[0] < preloaded.size()) {
                tracker.erase(preloaded.text(retired[0]++));
            }
            done.complete(event);
        };
        try (EventReceiver<ParcelEvent> receiver = new EventReceiver<>(config, Decoder.protobuf())) {
            System.out.printf("listening on %s, SO_RCVBUF requested %d, granted %d%n", receiver.localAddress(),
                    config.rcvbuf(), receiver.grantedRcvbuf());
            if (cpu >= 0) {
                Placement.announce(cpu, "receive");
            }
            System.out.println("ready: " + config.variant() + " on " + config.bindHost() + ":" + config.bindPort());
            System.out.flush(); // bound: a script reading a redirected stdout waits on this line
            EventReceiver.StopReason reason = receiver.run(handler);

            System.out.printf("stopped: %s; received %d, dropped %d, reordered %d, malformed %d%n", reason,
                    receiver.received(), receiver.dropped(), receiver.reordered(), receiver.malformed());
            LatencyRecorder recorder = receiver.recorder();
            recorder.printSummary();
            Path report = config.report();
            if (report != null) {
                String notes = "reordered=%d; malformed=%d; rcvbuf_requested=%d; rcvbuf_granted=%d; hub tracker preloaded, "
                        .formatted(receiver.reordered(), receiver.malformed(), config.rcvbuf(), receiver.grantedRcvbuf())
                        + "receive thread pinned";
                Map<String, Object> runtime = new LinkedHashMap<>(receiver.runtime());
                Map<String, Long> exact = new LinkedHashMap<>();
                exact.put("parcels", receiver.received());
                exact.put("preloaded", (long) preloaded.size());
                exact.put("in_flight_at_end", (long) tracker.size());
                runtime.put("counters", RuntimeInfo.counters(exact));
                if (cpu >= 0) {
                    runtime.put("placement", RuntimeInfo.placement(List.of(cpu), true, false));
                }
                recorder.writeReport(report, notes, null, runtime);
                System.out.println("report: " + report);
            }
            return reason == EventReceiver.StopReason.EXPECTED ? 0 : 1;
        } catch (EventReceiver.NegativeLatencyException e) {
            System.err.println("consume: aborting: " + e.getMessage());
            return 1;
        }
    }
}
