package io.patterncatalyst.lowlat.ch12;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.channels.DatagramChannel;
import java.util.Collections;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Each plain-JDK receive variant takes the same parcels over loopback, unpinned, with no modelled work. */
class ReceiveRunTest {

    private static final long PER_CAMERA = 300;

    @ParameterizedTest
    @ValueSource(strings = {"selector", "virtual-thread-blocking", "thread-per-core"})
    void everyVariantDecidesEveryParcel(String variant) throws Exception {
        DatagramChannel[] channels = ReceiveRun.open(new int[ReceiveRun.CAMERAS]);
        try {
            Thread feeder = Thread.ofPlatform().start(() -> ReceiveRun.feed(channels, PER_CAMERA));
            int threads = ReceiveRun.threadsFor(variant);
            ReceiveRun.Pass pass = ReceiveRun.pass(variant, channels, PER_CAMERA, Collections.nCopies(threads, -1),
                    new Placement.Gate(threads, 0, false), 0, 2_000);
            feeder.join();
            assertEquals(PER_CAMERA * ReceiveRun.CAMERAS, pass.sum(c -> c.parcels));
            assertEquals(0, pass.lost());
            assertEquals(0, pass.sum(c -> c.malformed));
            assertEquals(threads, pass.counters().size());
            assertTrue(pass.sum(c -> c.receives) >= pass.sum(c -> c.datagrams));
            assertEquals(variant.equals("selector"), pass.sum(c -> c.selects) > 0);
        } finally {
            ReceiveRun.close(channels);
        }
    }
}
