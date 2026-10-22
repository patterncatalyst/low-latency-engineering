package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.Config;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * The example's options on top of the common consumer ones ({@link Config}): the stages to run,
 * where the journal lives, the command channel's address and the thread placement.
 */
record Settings(
        Config config,
        Variant.JournalKind journal,
        Variant.ManifestKind manifest,
        Path journalDir,
        Config.HostPort commandBind,
        int manifestEntries,
        int slots,
        long sampleHoldMs,
        ThreadPlacement placement) {

    static final String USAGE = """
            usage: offheap-lockfree --variant NAME [--bind HOST:PORT] [--expect N] [--window N]
                                    [--report FILE] [--journal none|chronicle|file]
                                    [--manifest none|on-heap|chronicle-map] [--journal-dir DIR]
                                    [--command-bind HOST:PORT] [--manifest-entries N] [--slots N]
                                    [--sample-hold-ms MS] [--placement unpinned]
              --variant         blocking-queue | linked-queue | agrona-spsc | agrona-spsc-backoff |
                                disruptor | disruptor-blocking-wait | chronicle-journal |
                                write-per-parcel | chronicle-map-manifest | on-heap-manifest
              --journal         override the variant's journal stage
              --manifest        override the variant's manifest stage
              --journal-dir     directory for the journal files, removed at the end of the run
                                (default .scratch/offheap-lockfree under the working directory)
              --command-bind    UDP address of the diverter's command socket (default 127.0.0.1:47271)
              --manifest-entries manifest size (default 1000000)
              --slots           hand-off capacity in records, a power of two (default 65536)
              --sample-hold-ms  after the last parcel, keep the decide thread alive this long so a
                                script can read its context switches (default 0)
              --placement       decide-thread placement (default unpinned)
              the common consumer options (--rcvbuf, --idle-timeout-ms, --example) also apply
            """;

    static final String DEFAULT_EXAMPLE = "07-offheap-lockfree";
    static final int DEFAULT_PORT = 47270;
    static final int DEFAULT_COMMAND_PORT = 47271;
    static final long DEFAULT_WINDOW = 20_000;

    /** @throws IllegalArgumentException with a user-facing message; {@link Config.HelpRequested} for --help */
    static Settings parse(List<String> args) {
        Variant.JournalKind journalOverride = null;
        Variant.ManifestKind manifestOverride = null;
        Path journalDir = Path.of(".scratch", "offheap-lockfree");
        Config.HostPort commandBind = new Config.HostPort("127.0.0.1", DEFAULT_COMMAND_PORT);
        int manifestEntries = 1_000_000;
        int slots = 1 << 16;
        long holdMs = 0;
        ThreadPlacement placement = ThreadPlacement.UNPINNED;

        List<String> common = new ArrayList<>();
        for (int i = 0; i < args.size(); i++) {
            String flag = args.get(i);
            if (!isOwn(flag)) {
                common.add(flag);
                continue;
            }
            if (i + 1 >= args.size()) {
                throw new IllegalArgumentException("option " + flag + " needs a value");
            }
            String value = args.get(++i);
            switch (flag) {
                case "--journal" -> journalOverride = Variant.JournalKind.of(value);
                case "--manifest" -> manifestOverride = Variant.ManifestKind.of(value);
                case "--journal-dir" -> journalDir = Path.of(value);
                case "--command-bind" -> commandBind = Config.HostPort.parse(flag, value);
                case "--manifest-entries" -> manifestEntries = positive(flag, value);
                case "--slots" -> slots = positive(flag, value);
                case "--sample-hold-ms" -> holdMs = Long.parseLong(value);
                case "--placement" -> placement = ThreadPlacement.named(value);
                default -> throw new IllegalStateException(flag);
            }
        }
        if (Integer.bitCount(slots) != 1) {
            throw new IllegalArgumentException("--slots must be a power of two, got " + slots);
        }
        Config base = Config.parse(List.of("--bind", "127.0.0.1:" + DEFAULT_PORT, "--example", DEFAULT_EXAMPLE,
                "--variant", Variant.BLOCKING_QUEUE.label(), "--window", Long.toString(DEFAULT_WINDOW)));
        Config config = Config.parse(common, base);
        Variant variant = Variant.of(config.variant());
        return new Settings(config, journalOverride != null ? journalOverride : variant.journal(),
                manifestOverride != null ? manifestOverride : variant.manifest(), journalDir, commandBind,
                manifestEntries, slots, holdMs, placement);
    }

    Variant variant() {
        return Variant.of(config.variant());
    }

    private static boolean isOwn(String flag) {
        return switch (flag) {
            case "--journal", "--manifest", "--journal-dir", "--command-bind", "--manifest-entries", "--slots",
                    "--sample-hold-ms", "--placement" -> true;
            default -> false;
        };
    }

    private static int positive(String flag, String value) {
        try {
            int v = Integer.parseInt(value);
            if (v < 1) {
                throw new IllegalArgumentException(flag + " must be at least 1, got " + value);
            }
            return v;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(flag + " needs a number, got '" + value + "'", e);
        }
    }
}
