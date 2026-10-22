package io.patterncatalyst.lowlat.offheap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.lmax.disruptor.RingBuffer;
import java.nio.file.Path;
import net.openhft.affinity.Affinity;
import net.openhft.chronicle.queue.ChronicleQueue;
import net.openhft.chronicle.queue.ExcerptAppender;
import net.openhft.chronicle.queue.ExcerptTailer;
import org.agrona.concurrent.UnsafeBuffer;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Wiring proof: every 07 dependency loads, and Chronicle Queue opens, appends and tails under
 * the surefire argLine that carries its --add-opens/--add-exports list.
 */
class WiringTest {
    static {
        ChronicleAnalytics.disable();
    }

    @Test
    void dependenciesLoad() throws Exception {
        assertNotNull(RingBuffer.class);
        assertEquals(8, new UnsafeBuffer(new byte[8]).capacity());
        assertNotNull(Class.forName("net.openhft.chronicle.map.ChronicleMap"));
        assertNotNull(Class.forName("net.openhft.affinity.Affinity"));
        assertNotNull(Class.forName("io.patterncatalyst.lowlat.line.Consumer"));
        assertNotNull(WiringTest.class.getResource("/META-INF/BenchmarkList"), "JMH annotation processor ran");
    }

    /** Affinity reaches the OS through JNA 5.5.0 (the BOM's pin); prove it loads and answers on this JDK. */
    @Test
    void affinityReadsTheCurrentCpu() {
        assertTrue(Affinity.getCpu() >= 0);
        assertTrue(Affinity.getThreadId() > 0);
    }

    @Test
    void chronicleQueueRoundTrip(@TempDir Path dir) {
        try (ChronicleQueue queue = ChronicleQueue.singleBuilder(dir).build()) {
            ExcerptAppender appender = queue.createAppender();
            appender.writeText("scan-1");
            appender.writeText("scan-2");
            ExcerptTailer tailer = queue.createTailer();
            assertEquals("scan-1", tailer.readText());
            assertEquals("scan-2", tailer.readText());
        }
    }
}
