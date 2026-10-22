package io.patterncatalyst.lowlat.offheap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.line.v1.Dimensions;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

/** Every hand-off structure carries parcels in order, intact, and refuses (not blocks) when full. */
class HandOffTest {

    static ParcelEvent parcel(long seq) {
        return ParcelEvent.newBuilder()
                .setSeq(seq)
                .setIntendedEmitNs(seq * 1_000)
                .setEncoderTick(seq * 10)
                .setBarcode("00614141%09d".formatted(seq) + "0")
                .setWeightG(1_500 + (int) seq)
                .setDims(Dimensions.newBuilder().setLengthMm(300).setWidthMm(200).setHeightMm(100))
                .setScanConfidencePermille(990)
                .build();
    }

    /** Collects what the decide thread sees; copies each field, because a view is reused. */
    private static class CollectingSink implements ScanSink {
        final List<long[]> seen = new ArrayList<>();
        final CountDownLatch started = new CountDownLatch(1);
        volatile int count;

        @Override
        public void onStart() {
            started.countDown();
        }

        @Override
        public void onScan(ScanView scan, long pickupNs) {
            seen.add(new long[] {scan.seq(), scan.intendedNs(), scan.rxNs(), scan.serial(), scan.encoderTick(),
                    scan.weightG(), scan.lengthMm(), scan.widthMm(), scan.heightMm(), scan.confidencePermille(),
                    pickupNs});
            count = seen.size();
        }
    }

    @ParameterizedTest
    @EnumSource(Variant.HandOffKind.class)
    void carriesParcelsInOrderWithEveryField(Variant.HandOffKind kind) throws Exception {
        CollectingSink sink = new CollectingSink();
        try (HandOff handOff = kind.create(1 << 10)) {
            handOff.start(sink, ThreadPlacement.UNPINNED);
            assertTrue(sink.started.await(10, TimeUnit.SECONDS));
            int n = 500;
            for (long seq = 0; seq < n; seq++) {
                while (!handOff.publish(parcel(seq), 5_000 + seq)) {
                    Thread.onSpinWait();
                }
            }
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            while (sink.count < n && System.nanoTime() < deadline) {
                LockSupport.parkNanos(1_000_000);
            }
            assertNull(handOff.failure());
            assertEquals(n, sink.count);
        }
        for (int i = 0; i < sink.seen.size(); i++) {
            long[] s = sink.seen.get(i);
            assertEquals(i, s[0], "order");
            assertEquals(i * 1_000L, s[1]);
            assertEquals(5_000L + i, s[2], "the receive stamp travels with the parcel");
            assertEquals(i, s[3], "serial reference is digits 8..16 of the barcode");
            assertEquals(i * 10L, s[4]);
            assertEquals(1_500 + i, s[5]);
            assertEquals(300, s[6]);
            assertEquals(200, s[7]);
            assertEquals(100, s[8]);
            assertEquals(990, s[9]);
            assertTrue(s[10] > 0);
        }
    }

    /** A stalled consumer must not block the producer: the belt does not wait. */
    @ParameterizedTest
    @EnumSource(Variant.HandOffKind.class)
    void refusesWhenFull(Variant.HandOffKind kind) throws Exception {
        CountDownLatch release = new CountDownLatch(1);
        CollectingSink sink = new CollectingSink() {
            @Override
            public void onScan(ScanView scan, long pickupNs) {
                try {
                    release.await();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
                super.onScan(scan, pickupNs);
            }
        };
        try (HandOff handOff = kind.create(16)) {
            handOff.start(sink, ThreadPlacement.UNPINNED);
            assertTrue(sink.started.await(10, TimeUnit.SECONDS));
            int accepted = 0;
            boolean refused = false;
            for (long seq = 0; seq < 1_000 && !refused; seq++) {
                if (handOff.publish(parcel(seq), seq)) {
                    accepted++;
                } else {
                    refused = true;
                }
            }
            assertTrue(refused, "a full hand-off returns false");
            assertTrue(accepted >= 1 && accepted <= 17, "accepted " + accepted);
            release.countDown();
        }
    }

    @Test
    void serialIsTheNineDigitReference() {
        assertEquals(123_456_789L, Barcode.serial("006141411234567896"));
        assertEquals(0, Barcode.serial("006141410000000000"));
    }
}
