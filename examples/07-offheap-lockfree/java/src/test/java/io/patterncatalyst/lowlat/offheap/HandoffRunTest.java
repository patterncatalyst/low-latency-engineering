package io.patterncatalyst.lowlat.offheap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.net.InetSocketAddress;
import java.net.StandardProtocolFamily;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Whole pipeline, in process: a sender thread plays the line simulator (UDP on 47272), a
 * variant receives, hands off, decides, sends divert commands (UDP on 47273) and journals.
 */
class HandoffRunTest {

    private static final int DATA_PORT = 47272;
    private static final int COMMAND_PORT = 47273;
    private static final int PARCELS = 2_000;

    private static Handoff.Result run(List<String> extra, Path scratch) throws Exception {
        ByteArrayOutputStream captured = new ByteArrayOutputStream();
        PrintStream out = new PrintStream(captured, true, StandardCharsets.UTF_8);
        List<String> args = new ArrayList<>(List.of("--bind", "127.0.0.1:" + DATA_PORT,
                "--command-bind", "127.0.0.1:" + COMMAND_PORT, "--expect", Integer.toString(PARCELS),
                "--idle-timeout-ms", "5000", "--window", "500", "--journal-dir", scratch.toString()));
        args.addAll(extra);
        Settings settings = Settings.parse(args);

        FutureTask<Handoff.Result> pipeline = new FutureTask<>(() -> Handoff.run(settings, out));
        Thread receive = Thread.ofPlatform().name("test-pipeline").start(pipeline);
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
        while (!captured.toString(StandardCharsets.UTF_8).contains("listening on")) {
            assertFalse(pipeline.isDone(), "pipeline ended before it bound: " + captured);
            assertTrue(System.nanoTime() < deadline, "pipeline never bound");
            LockSupport.parkNanos(1_000_000);
        }
        sendParcels();
        receive.join(TimeUnit.SECONDS.toMillis(60));
        assertTrue(pipeline.isDone(), "pipeline did not finish: " + captured);
        String log = captured.toString(StandardCharsets.UTF_8);
        assertTrue(log.contains("decide-thread pid="), log);
        assertTrue(log.contains("window-end handled=" + PARCELS), log);
        return pipeline.get();
    }

    /** The line: one parcel every 200 microseconds, each stamped with the time it should have left. */
    private static void sendParcels() throws IOException {
        try (DatagramChannel channel = DatagramChannel.open(StandardProtocolFamily.INET)) {
            channel.connect(new InetSocketAddress("127.0.0.1", DATA_PORT));
            for (int seq = 0; seq < PARCELS; seq++) {
                long now = System.nanoTime();
                byte[] bytes = HandOffTest.parcel(seq).toBuilder().setIntendedEmitNs(now).setActualEmitNs(now)
                        .build().toByteArray();
                channel.write(ByteBuffer.wrap(bytes));
                LockSupport.parkNanos(200_000);
            }
        }
    }

    @Test
    void everyHandOffDeliversEveryParcelAndEveryCommand(@TempDir Path scratch) throws Exception {
        for (Variant variant : List.of(Variant.BLOCKING_QUEUE, Variant.AGRONA_SPSC, Variant.DISRUPTOR_BLOCKING_WAIT)) {
            Handoff.Result r = run(List.of("--variant", variant.label()), scratch);
            assertEquals(PARCELS, r.received(), variant.label());
            assertEquals(PARCELS, r.published());
            assertEquals(0, r.overflow());
            assertEquals(PARCELS, r.handled());
            assertEquals(PARCELS, r.divertReceived(), "every divert command arrived on the command socket");
        }
    }

    @Test
    void chronicleJournalAndChronicleMapComposeWithTheRing(@TempDir Path scratch) throws Exception {
        Handoff.Result r = run(List.of("--variant", "agrona-spsc", "--journal", "chronicle", "--manifest",
                "chronicle-map", "--manifest-entries", "5000"), scratch);
        assertEquals(PARCELS, r.handled());
        assertEquals(new Journal.Readback(PARCELS, true), r.journal());
        assertEquals(PARCELS, r.manifestHits());
        assertEquals(PARCELS, r.divertReceived());
        try (var left = Files.list(scratch)) {
            assertEquals(0, left.count(), "the run removed its journal files");
        }
    }

    @Test
    void filePerParcelJournalReadsBack(@TempDir Path scratch) throws Exception {
        Handoff.Result r = run(List.of("--variant", "write-per-parcel"), scratch);
        assertEquals(new Journal.Readback(PARCELS, true), r.journal());
    }
}
