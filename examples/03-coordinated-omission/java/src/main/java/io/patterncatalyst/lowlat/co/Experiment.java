package io.patterncatalyst.lowlat.co;

import com.google.protobuf.InvalidProtocolBufferException;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.SocketTimeoutException;
import java.nio.ByteBuffer;
import java.time.Duration;

/**
 * One stall, measured three ways. The receive phase records {@code receipt-time} and
 * {@code intended-time} from the same datagrams; the closed-loop phase records one request
 * stream plain and through {@code recordCorrected}.
 */
final class Experiment {

    /** The corrected recorder back-fills at the rate a well-behaved client would have sent. */
    static final long EXPECTED_INTERVAL_NS = 1_000_000L;

    private static volatile int sink; // keeps the "handle" step from being optimised away

    private Experiment() {
    }

    /**
     * The stall: a blocking sleep, which models a GC pause, a page fault or a lock convoy.
     * It is the one place in this example where sleeping is the right tool.
     */
    static void stall(long ms) {
        try {
            Thread.sleep(Duration.ofMillis(ms));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /** Receive {@code expect} parcels; returns the number that never arrived. */
    static long receive(Options o, DatagramSocket socket, Recorders rec) throws IOException {
        socket.setSoTimeout(100); // bounds the idle check
        byte[] buf = new byte[2048];
        DatagramPacket packet = new DatagramPacket(buf, buf.length);
        long nextSeq = 0;
        long received = 0;
        long dropped = 0;
        long lastRxNs = 0;
        boolean started = false;
        while (received + dropped < o.expect()) {
            try {
                socket.receive(packet);
            } catch (SocketTimeoutException idle) {
                if (started && System.nanoTime() - lastRxNs >= o.idleTimeoutMs() * 1_000_000L) {
                    break;
                }
                continue;
            }
            // Just dequeued: this is where a service-side timer starts its clock, however
            // long the parcel waited in the socket buffer.
            long dequeuedNs = System.nanoTime();
            started = true;
            lastRxNs = dequeuedNs;
            ParcelEvent event;
            try {
                event = ParcelEvent.parseFrom(ByteBuffer.wrap(buf, 0, packet.getLength()));
            } catch (InvalidProtocolBufferException e) {
                continue;
            }
            if (event.getSeq() < nextSeq) {
                continue; // reordered or repeated
            }
            dropped += event.getSeq() - nextSeq;
            nextSeq = event.getSeq() + 1;
            received++;

            sink = Handle.laneOf(event.getBarcode());
            if (o.stallMs() > 0 && event.getSeq() == o.stallSeq()) {
                stall(o.stallMs());
            }
            long doneNs = System.nanoTime();
            rec.receiptTime().record(doneNs - dequeuedNs);
            rec.intendedTime().record(doneNs - event.getIntendedEmitNs());
        }
        rec.receiptTime().addDropped(dropped);
        rec.intendedTime().addDropped(dropped);
        return dropped;
    }

    /**
     * {@code requests} closed-loop requests, one per interval: each starts, handles one parcel,
     * finishes, and only then is the next issued. Request {@code stallSeq} stalls.
     */
    static void closedLoop(Options o, long requests, Recorders rec) {
        String barcode = "006141410000000134";
        for (long i = 0; i < requests; i++) {
            long startNs = System.nanoTime();
            sink = Handle.laneOf(barcode);
            if (o.stallMs() > 0 && i == o.stallSeq()) {
                stall(o.stallMs());
            }
            long latencyNs = System.nanoTime() - startNs;
            rec.closedLoopNaive().record(latencyNs);
            rec.closedLoopCorrected().recordCorrected(latencyNs, EXPECTED_INTERVAL_NS);

            // Closed loop: the next request is issued only now. Nothing queues behind the
            // stall, so nothing is measured as having waited.
            long waitNs = startNs + EXPECTED_INTERVAL_NS - System.nanoTime();
            if (waitNs > 0) {
                try {
                    Thread.sleep(Duration.ofNanos(waitNs));
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
    }
}
