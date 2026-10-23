package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.io.IOException;
import java.lang.foreign.MemorySegment;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/** {@code --window}, a Completion owned by a decide thread, receive-thread allocation, the Decoder seam. */
class WindowAndOwnershipTest {

    private static final String BARCODE = "006141410000000008";

    private static Config config(long expect, long window) {
        List<String> args = window > 0
                ? List.of("--bind", "127.0.0.1:0", "--expect", Long.toString(expect), "--idle-timeout-ms", "5000",
                        "--window", Long.toString(window), "--variant", "warmed")
                : List.of("--bind", "127.0.0.1:0", "--expect", Long.toString(expect), "--idle-timeout-ms", "5000");
        return Config.parse(args);
    }

    private static void sendProtobuf(InetSocketAddress to, long... seqs) throws IOException {
        try (DatagramChannel tx = DatagramChannel.open()) {
            for (long seq : seqs) {
                ParcelEvent event = ParcelEvent.newBuilder().setSeq(seq).setIntendedEmitNs(System.nanoTime())
                        .setBarcode(BARCODE).build();
                tx.send(ByteBuffer.wrap(event.toByteArray()), to);
            }
        }
    }

    private static void sendProtobufRange(InetSocketAddress to, int count) throws IOException {
        long[] seqs = new long[count];
        for (int i = 0; i < count; i++) {
            seqs[i] = i;
        }
        sendProtobuf(to, seqs);
    }

    private static void sendFlatRange(InetSocketAddress to, int count) throws IOException {
        ByteBuffer datagram = ByteBuffer.allocateDirect(FlatParcel.SIZE);
        MemorySegment segment = MemorySegment.ofBuffer(datagram);
        try (DatagramChannel tx = DatagramChannel.open()) {
            for (int seq = 0; seq < count; seq++) {
                FlatParcel.write(segment, 0, seq, System.nanoTime(), 0, BARCODE);
                datagram.clear();
                tx.send(datagram, to);
            }
        }
    }

    // --- windows ---------------------------------------------------------------

    @Test
    void configParsesWindow() {
        assertEquals(0, Config.parse(List.of()).window());
        assertEquals(2000, Config.parse(List.of("--window", "2000")).window());
        assertThrows(IllegalArgumentException.class, () -> Config.parse(List.of("--window", "0")));
        assertThrows(IllegalArgumentException.class, () -> Config.parse(List.of("--window", "x")));
    }

    @Test
    void gapTrackerBooksDropsInTheirWindow() {
        GapTracker t = new GapTracker(10);
        t.observe(0);
        t.observe(1);
        t.observe(4); // 2, 3 missing
        assertEquals(2, t.droppedBelowWindow());
        t.observe(14); // 5..13 missing: 5..9 below, 10..13 not
        assertEquals(11, t.dropped());
        assertEquals(7, t.droppedBelowWindow());
        t.observe(20);
        assertEquals(7, t.droppedBelowWindow());
        assertEquals(16, t.dropped());
    }

    @Test
    void reportPathsAreSiblingsOfTheReport() {
        assertEquals(Path.of("/tmp/x/run-first-5.json"), WindowedRecorders.sibling(Path.of("/tmp/x/run.json"), "-first-5"));
        assertEquals(Path.of("run-steady.json"), WindowedRecorders.sibling(Path.of("run.json"), "-steady"));
        assertEquals(Path.of("run-steady"), WindowedRecorders.sibling(Path.of("run"), "-steady"));
    }

    @Test
    void twoWindowsSumToTheTotalAndBothReportsAreWritten(@TempDir Path dir) throws Exception {
        try (LineReceiver receiver = new LineReceiver(config(500, 200))) {
            sendProtobufRange(receiver.localAddress(), 500);
            receiver.run((event, done) -> done.complete(event));

            WindowedRecorders w = receiver.windows();
            assertEquals(200, w.first().histogram().getTotalCount());
            assertEquals(300, w.steady().histogram().getTotalCount());
            assertEquals(receiver.recorder().histogram().getTotalCount(),
                    w.first().histogram().getTotalCount() + w.steady().histogram().getTotalCount());

            Path report = dir.resolve("warmed.json");
            receiver.recorder().writeReport(report, "n", null, receiver.runtime());
            assertTrue(receiver.runtime().containsKey("alloc_bytes_per_parcel"));
            assertFalse(receiver.windowRuntime().containsKey("alloc_bytes_per_parcel"),
                    "the whole-run allocation must not be reported as a window's figure");
            List<Path> written = w.writeReports(report, "n", receiver.windowRuntime());
            assertEquals(List.of(dir.resolve("warmed-first-200.json"), dir.resolve("warmed-steady.json")), written);
            String first = Files.readString(written.get(0));
            assertTrue(first.contains("\"variant\" : \"warmed-first-200\""), first);
            assertTrue(Files.readString(written.get(1)).contains("\"variant\" : \"warmed-steady\""));
            assertFalse(first.contains("alloc_bytes_per_parcel"), first);
            assertTrue(Files.readString(report).contains("alloc_bytes_per_parcel"));
        }
    }

    @Test
    void windowedDropsAreSplitToo() throws Exception {
        try (LineReceiver receiver = new LineReceiver(config(10, 4))) {
            sendProtobuf(receiver.localAddress(), 0, 1, 2, 6, 9); // 3,4,5 (3 below 4) and 7,8 missing
            receiver.run((event, done) -> done.complete(event));
            WindowedRecorders w = receiver.windows();
            assertEquals(5, receiver.dropped());
            assertEquals(1, w.first().report().dropped());
            assertEquals(4, w.steady().report().dropped());
            assertEquals(3, w.first().histogram().getTotalCount());
            assertEquals(2, w.steady().histogram().getTotalCount());
        }
    }

    @Test
    void noWindowMeansNoWindowRecorders() throws Exception {
        try (LineReceiver receiver = new LineReceiver(config(1, 0))) {
            assertNull(receiver.windows());
        }
    }

    // --- Completion owned by another thread ------------------------------------

    /** The receive thread only enqueues; a decide thread owns the Completion; drain joins it. */
    private static final class DecideThread implements ParcelHandler {
        private record Item(long seq, long intendedNs) {
        }

        private static final Item POISON = new Item(-1, 0);
        private final BlockingQueue<Item> queue = new LinkedBlockingQueue<>();
        private Thread worker;
        volatile Thread decideThread; // written by the worker; read after the join

        @Override
        public void onParcel(ParcelEvent event, Completion done) {
            if (worker == null) {
                worker = Thread.ofPlatform().name("decide").start(() -> decide(done));
            }
            queue.add(new Item(event.getSeq(), event.getIntendedEmitNs()));
        }

        private void decide(Completion done) {
            decideThread = Thread.currentThread();
            try {
                for (Item item = queue.take(); item != POISON; item = queue.take()) {
                    done.complete(item.seq(), item.intendedNs(), System.nanoTime());
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }

        @Override
        public void drain(Completion done) {
            if (worker == null) {
                return;
            }
            queue.add(POISON);
            try {
                worker.join(); // the happens-before edge that publishes the recorder
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }

    @Test
    void completionOnASecondThreadRecordsEveryReceivedParcel() throws Exception {
        DecideThread handler = new DecideThread();
        try (LineReceiver receiver = new LineReceiver(config(400, 100))) {
            sendProtobufRange(receiver.localAddress(), 400);
            Thread receiveThread = Thread.currentThread();
            receiver.run(handler);

            assertEquals(400, receiver.received());
            assertNotNull(handler.decideThread);
            assertNotEquals(receiveThread, handler.decideThread);
            assertEquals(receiver.received(), receiver.completion().count());
            assertEquals(receiver.received(), receiver.recorder().histogram().getTotalCount());
            WindowedRecorders w = receiver.windows();
            assertEquals(100, w.first().histogram().getTotalCount());
            assertEquals(300, w.steady().histogram().getTotalCount());
            assertTrue(receiver.completion().firstDoneNs() <= receiver.completion().lastDoneNs());
        }
    }

    // --- Receive-thread allocation ----------------------------------------------

    @Test
    void runtimeBlockCarriesAllocatedBytesPerParcel() throws Exception {
        try (LineReceiver receiver = new LineReceiver(config(300, 0))) {
            sendProtobufRange(receiver.localAddress(), 300);
            receiver.run((event, done) -> done.complete(event));

            assertTrue(receiver.receiveAllocatedBytes() > 0, "allocated " + receiver.receiveAllocatedBytes());
            Map<String, Object> runtime = receiver.runtime();
            assertTrue(runtime.containsKey("gc"));
            double perParcel = (Double) runtime.get("alloc_bytes_per_parcel");
            assertEquals((double) receiver.receiveAllocatedBytes() / 300, perParcel);
        }
    }

    // --- Decoder seam ------------------------------------------------------------

    @Test
    void aFlatDecoderFeedsTheSameLoopAndAllocatesLessThanProtobuf() throws Exception {
        int count = 2000;
        double flatPerParcel;
        try (EventReceiver<FlatParcel> receiver = new EventReceiver<>(config(count, 0), new FlatParcel.FlatDecoder())) {
            sendFlatRange(receiver.localAddress(), count);
            receiver.run((view, done) -> done.complete(view.seq(), view.intendedEmitNs(), System.nanoTime()));
            assertEquals(count, receiver.received());
            assertEquals(count, receiver.recorder().histogram().getTotalCount());
            assertEquals(0, receiver.malformed());
            flatPerParcel = (Double) receiver.runtime().get("alloc_bytes_per_parcel");
        }
        double protobufPerParcel;
        try (LineReceiver receiver = new LineReceiver(config(count, 0))) {
            sendProtobufRange(receiver.localAddress(), count);
            receiver.run((event, done) -> done.complete(event));
            protobufPerParcel = (Double) receiver.runtime().get("alloc_bytes_per_parcel");
        }
        assertTrue(flatPerParcel < protobufPerParcel,
                "flat " + flatPerParcel + " B/parcel should be below protobuf " + protobufPerParcel);
    }

    @Test
    void aMalformedDatagramIsCountedNotFatal() throws Exception {
        try (EventReceiver<FlatParcel> receiver = new EventReceiver<>(config(2, 0), new FlatParcel.FlatDecoder())) {
            try (DatagramChannel tx = DatagramChannel.open()) {
                tx.send(ByteBuffer.wrap(new byte[] {1, 2, 3}), receiver.localAddress());
            }
            sendFlatRange(receiver.localAddress(), 2);
            receiver.run((view, done) -> done.complete(view.seq(), view.intendedEmitNs(), System.nanoTime()));
            assertEquals(1, receiver.malformed());
            assertEquals(2, receiver.received());
        }
    }
}
