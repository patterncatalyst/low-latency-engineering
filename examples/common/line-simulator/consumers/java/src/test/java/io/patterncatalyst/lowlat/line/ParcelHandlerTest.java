package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

/** The handler hook: a handler may hold parcels, complete them later, and drain the rest. */
class ParcelHandlerTest {

    private static final int PORT = 47104;
    private static final String BARCODE = "006141410000000008";

    private static LineReceiver receiverFor(long expect) throws Exception {
        return new LineReceiver(Config.parse(List.of("--bind", "127.0.0.1:" + PORT, "--expect", Long.toString(expect),
                "--idle-timeout-ms", "5000")));
    }

    private static void send(LineReceiver receiver, long... seqs) throws Exception {
        InetSocketAddress to = receiver.localAddress();
        try (DatagramChannel tx = DatagramChannel.open()) {
            for (long seq : seqs) {
                ParcelEvent event = ParcelEvent.newBuilder().setSeq(seq).setIntendedEmitNs(System.nanoTime())
                        .setBarcode(BARCODE).build();
                tx.send(ByteBuffer.wrap(event.toByteArray()), to);
            }
        }
    }

    @Test
    void completesInsideTheCall() throws Exception {
        try (LineReceiver receiver = receiverFor(3)) {
            send(receiver, 0, 1, 2);
            assertEquals(LineReceiver.StopReason.EXPECTED, receiver.run((event, done) -> done.complete(event)));
            assertEquals(3, receiver.completion().count());
            assertEquals(3, receiver.recorder().histogram().getTotalCount());
            assertTrue(receiver.completion().firstDoneNs() <= receiver.completion().lastDoneNs());
        }
    }

    @Test
    void deferredCompletionAndDrain() throws Exception {
        List<Long> held = new ArrayList<>();
        ParcelHandler batchOfTwo = new ParcelHandler() {
            @Override
            public void onParcel(ParcelEvent event, Completion done) {
                held.add(event.getIntendedEmitNs());
                if (held.size() == 2) {
                    drain(done);
                }
            }

            @Override
            public void drain(Completion done) {
                long doneNs = System.nanoTime();
                held.forEach(intended -> done.complete(intended, doneNs));
                held.clear();
            }
        };
        try (LineReceiver receiver = receiverFor(3)) {
            send(receiver, 0, 1, 2);
            receiver.run(batchOfTwo); // two completed in the loop, the third by drain
            assertEquals(3, receiver.completion().count());
            assertEquals(3, receiver.recorder().histogram().getTotalCount());
        }
    }

    @Test
    void gapsAreBookedAsDropped() throws Exception {
        try (LineReceiver receiver = receiverFor(4)) {
            send(receiver, 0, 3);
            receiver.run((event, done) -> done.complete(event));
            assertEquals(2, receiver.dropped());
            assertEquals(2, receiver.completion().count());
        }
    }
}
