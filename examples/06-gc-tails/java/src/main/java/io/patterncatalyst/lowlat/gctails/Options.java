package io.patterncatalyst.lowlat.gctails;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * The flags this example adds to the common consumer's: the size of the heap workload, the
 * warm-up and where the in-process flight recording goes. Everything else is passed on to
 * {@link io.patterncatalyst.lowlat.line.Config#parse}.
 *
 * @param settings the tracker's heap workload
 * @param warmUp synthetic parcels to run through the tracker before the socket is bound
 * @param jfr file the in-process recording is written to, or {@code null} for no recording
 * @param probe populate the heap, print its live set and exit
 * @param rest the arguments for the common consumer parser
 */
record Options(Settings settings, int warmUp, Path jfr, boolean probe, List<String> rest) {

    static final String USAGE = """
            usage: gctails-java [--variant NAME] [--bind HOST:PORT] [--expect N] [--report FILE]
                                [--example NAME] [--rcvbuf BYTES] [--idle-timeout-ms MS]
                                [--rate HZ] [--live-set-mb MB] [--entry-bytes B]
                                [--alloc-mb-per-s MB] [--in-flight-ms MS] [--warm-up N]
                                [--jfr FILE] [--probe]
              --rate            parcels per second the simulator sends (default 10000)
              --live-set-mb     target size of the rolling shift manifest (default 1750)
              --entry-bytes     label bytes per manifest entry (default 4096)
              --alloc-mb-per-s  scan-history allocation rate in MB/s (default 400)
              --in-flight-ms    time between scanner and diverter (default 480)
              --warm-up         synthetic parcels run before the bind (default 30000)
              --jfr             record the measured run in-process and write the recording here
              --probe           populate, print live_set_bytes and exit (sizes --undersized-heap)
            """;

    static Options parse(String[] args) {
        Settings defaults = Settings.defaults();
        long rate = defaults.rate();
        long liveSetMb = defaults.liveSetBytes() >> 20;
        int entryBytes = defaults.entryBytes();
        long allocMbPerS = defaults.allocBytesPerSecond() >> 20;
        int inFlightMs = defaults.inFlightMs();
        int warmUp = 30_000;
        Path jfr = null;
        boolean probe = false;
        List<String> rest = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--probe" -> probe = true;
                case "--rate" -> rate = number(args, ++i);
                case "--live-set-mb" -> liveSetMb = number(args, ++i);
                case "--entry-bytes" -> entryBytes = Math.toIntExact(number(args, ++i));
                case "--alloc-mb-per-s" -> allocMbPerS = number(args, ++i);
                case "--in-flight-ms" -> inFlightMs = Math.toIntExact(number(args, ++i));
                case "--warm-up" -> warmUp = Math.toIntExact(number(args, ++i));
                case "--jfr" -> jfr = Path.of(value(args, ++i));
                default -> rest.add(args[i]);
            }
        }
        Settings settings = new Settings(rate, liveSetMb << 20, entryBytes, allocMbPerS << 20, inFlightMs,
                defaults.retainedSamples());
        return new Options(settings, warmUp, jfr, probe, List.copyOf(rest));
    }

    private static String value(String[] args, int i) {
        if (i >= args.length) {
            throw new IllegalArgumentException("option " + args[i - 1] + " needs a value");
        }
        return args[i];
    }

    private static long number(String[] args, int i) {
        String text = value(args, i);
        try {
            return Long.parseLong(text);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(args[i - 1] + " needs a number, got '" + text + "'", e);
        }
    }
}
