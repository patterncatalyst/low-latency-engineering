package io.patterncatalyst.lowlat.offheap;

import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.Decoder;
import io.patterncatalyst.lowlat.line.EventReceiver;
import io.patterncatalyst.lowlat.line.WindowedRecorders;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.io.IOException;
import java.io.PrintStream;
import java.net.InetSocketAddress;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.locks.LockSupport;
import java.util.stream.Stream;

/**
 * Ch7 example: the receive thread hands each parcel to a decide thread, which sends the divert
 * command on its own socket and appends every scan to an audit journal. Ten variants swap one
 * stage each (see {@link Variant}); every run records the end-to-end latency, the hand-off
 * latency and, where the stage exists, the journal-append, manifest-lookup and divert-command
 * latencies as separate reports.
 */
public final class Handoff {

    /** What a run measured, for the tests; the reports hold the distributions. */
    record Result(long received, long published, long overflow, long handled, long divertReceived,
            Journal.Readback journal, long manifestHits, long oldGenBaselineBytes, long oldGenAfterGcBytes, String journalFileSystem,
            long journalBytes, String journalSettings) {
    }

    private Handoff() {
    }

    public static void main(String[] args) throws Exception {
        ChronicleAnalytics.disable();
        Settings settings;
        try {
            settings = Settings.parse(List.of(args));
        } catch (Config.HelpRequested e) {
            System.out.print(Settings.USAGE);
            return;
        } catch (IllegalArgumentException e) {
            System.err.println("offheap-lockfree: " + e.getMessage());
            System.err.print(Settings.USAGE);
            System.exit(2);
            return;
        }
        if (settings.config().report() != null && !LatencyRecorder.profileConfigured()) {
            System.err.println("offheap-lockfree: --report needs " + LatencyRecorder.PROFILE_ENV);
            System.exit(2);
        }
        run(settings, System.out);
    }

    /**
     * Runs one variant to its stop condition. The order matters to a script: every stage that
     * takes time (the manifest load, the journal) is built first, then the data socket is bound,
     * then the decide thread prints its id, so "bound" means "ready for the first parcel".
     */
    static Result run(Settings settings, PrintStream out) throws IOException {
        Config config = settings.config();
        Variant variant = settings.variant();
        Files.createDirectories(settings.journalDir());
        Path journalDir = Files.createTempDirectory(settings.journalDir(), config.variant() + "-"); // ours to delete
        long oldGenBaseline = OldGen.usedAfterGc();
        try (Manifest manifest = settings.manifest().open(settings.manifestEntries());
                Journal journal = settings.journal().open(journalDir);
                Diverter diverter = new Diverter(new InetSocketAddress(settings.commandBind().host(), settings.commandBind().port()), config.example(),
                        config.variant());
                CommandChannel commands = new CommandChannel(diverter.address());
                HandOff handOff = variant.handOff().create(settings.slots());
                EventReceiver<ParcelEvent> receiver = new EventReceiver<>(config, Decoder.protobuf())) {
            DecideStage stage = new DecideStage(receiver.completion(), commands, journal, manifest,
                    config.example(), config.variant(), config.window(), out);
            handOff.start(stage, settings.placement());
            ScanHandler handler = new ScanHandler(handOff, stage, settings.sampleHoldMs(), out);
            out.printf("offheap-lockfree: variant %s listening on %s, commands to %s, window %d%n", config.variant(),
                    receiver.localAddress(), diverter.address(), config.window());
            out.flush(); // bound: a script reading a redirected stdout waits on this line

            EventReceiver.StopReason reason = receiver.run(handler);
            if (diverter.failure() != null) {
                throw new IllegalStateException("diverter listener died", diverter.failure());
            }
            awaitDiverter(diverter, handler.published());
            out.printf("received %d dropped %d reordered %d published %d overflow %d (stopped: %s)%n",
                    receiver.received(), receiver.dropped(), receiver.reordered(), handler.published(),
                    handler.overflow(), reason);

            Journal.Readback readback = journal == null ? null : journal.readBack();
            if (readback != null) {
                out.printf("journal-readback count=%d in_order=%b%n", readback.count(), readback.inOrder());
            }
            long oldGenAfter = OldGen.usedAfterGc();
            out.printf("old-gen bytes_after_gc=%d baseline_bytes=%d%n", oldGenAfter, oldGenBaseline);

            diverter.stop(); // joins the listener: its recorder is safe to read
            String journalFileSystem = journal == null ? null : Files.getFileStore(journalDir).type();
            long journalBytes = journal == null ? 0 : journal.bytes();
            String journalSettings = journal == null ? "" : journal.settings();
            Result result = new Result(receiver.received(), handler.published(), handler.overflow(),
                    stage.handled(), diverter.received(), readback, stage.manifestHits(), oldGenBaseline,
                    oldGenAfter, journalFileSystem, journalBytes, journalSettings);
            if (config.report() != null) {
                writeReports(settings, receiver, stage, diverter, result, out);
            }
            return result;
        } finally {
            deleteTree(journalDir);
        }
    }

    /** The command listener has the last few datagrams still in flight when the data path stops. */
    private static void awaitDiverter(Diverter diverter, long expected) {
        long deadline = System.nanoTime() + 5_000_000_000L;
        while (diverter.received() < expected && System.nanoTime() < deadline) {
            LockSupport.parkNanos(1_000_000);
        }
    }

    private static void writeReports(Settings settings, EventReceiver<ParcelEvent> receiver, DecideStage stage,
            Diverter diverter, Result result, PrintStream out) {
        Config config = settings.config();
        Path report = config.report();
        String notes = notes(settings, receiver, result);

        LatencyRecorder endToEnd = receiver.recorder();
        endToEnd.printSummary();
        endToEnd.writeReport(report, notes, null, receiver.runtime(oldGen(result)));
        out.println("report: " + report);
        for (Path window : receiver.windows().writeReports(report, notes, receiver.windowRuntime(oldGen(result)))) {
            out.println("report: " + window);
        }

        stage.handoff().all().printSummary();
        writeSplit(stage.handoff(), WindowedRecorders.sibling(report, "-handoff"), notes, out);
        if (result.journal() != null) {
            stage.journalAppend().all().printSummary();
            writeSplit(stage.journalAppend(), WindowedRecorders.sibling(report, "-journal-append"), notes, out);
        }
        if (settings.manifest() != Variant.ManifestKind.NONE) {
            stage.manifestLookup().all().printSummary();
            writeSplit(stage.manifestLookup(), WindowedRecorders.sibling(report, "-manifest-lookup"), notes, out);
        }
        diverter.latency().printSummary();
        write(diverter.latency(), WindowedRecorders.sibling(report, "-divert"), notes, out);
    }

    /** {@code gc.old_gen_used_bytes}: the old generation after a collection at the end of the run. */
    private static Map<String, Long> oldGen(Result result) {
        return Map.of("old_gen_used_bytes", result.oldGenAfterGcBytes());
    }

    private static void writeSplit(SplitRecorder recorder, Path path, String notes, PrintStream out) {
        recorder.writeReports(path, notes);
        out.println("report: " + path);
    }

    private static void write(LatencyRecorder recorder, Path path, String notes, PrintStream out) {
        recorder.writeReport(path, notes, null, RuntimeInfo.jvm());
        out.println("report: " + path);
    }

    /** What the histograms alone do not say, as {@code key=value} pairs a script can read. */
    private static String notes(Settings settings, EventReceiver<ParcelEvent> receiver, Result result) {
        StringBuilder notes = new StringBuilder();
        notes.append("handoff=").append(settings.variant().handOff().name().toLowerCase(Locale.ROOT))
                .append("; journal=").append(settings.journal().name().toLowerCase(Locale.ROOT))
                .append("; manifest=").append(settings.manifest().name().toLowerCase(Locale.ROOT))
                .append("; published=").append(result.published())
                .append("; overflow=").append(result.overflow())
                .append("; divert_received=").append(result.divertReceived())
                .append("; reordered=").append(receiver.reordered())
                .append("; rcvbuf_granted=").append(receiver.grantedRcvbuf())
                .append("; slots=").append(settings.slots())
                .append("; placement=").append(settings.placement().label());
        if (result.journal() != null) {
            notes.append("; journal_fs=").append(result.journalFileSystem())
                    .append("; journal_bytes=").append(result.journalBytes())
                    .append(result.journalSettings().isEmpty() ? "" : "; journal_" + result.journalSettings().replace("; ", "; journal_"))
                    .append("; journal_readback_count=").append(result.journal().count())
                    .append("; journal_in_order=").append(result.journal().inOrder());
        }
        if (settings.manifest() != Variant.ManifestKind.NONE) {
            notes.append("; manifest_entries=").append(settings.manifestEntries())
                    .append("; manifest_hits=").append(result.manifestHits());
        }
        notes.append("; old_gen_baseline_bytes=").append(result.oldGenBaselineBytes());
        return notes.toString();
    }

    private static void deleteTree(Path directory) throws IOException {
        if (!Files.exists(directory)) {
            return;
        }
        List<Path> deepestFirst;
        try (Stream<Path> paths = Files.walk(directory)) {
            deepestFirst = paths.sorted(Comparator.reverseOrder()).toList();
        }
        for (Path path : deepestFirst) {
            Files.delete(path);
        }
    }
}
