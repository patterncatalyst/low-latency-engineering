package io.patterncatalyst.lowlat.lockfree;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class MailboxAndRegistrationTest {

    @ParameterizedTest
    @ValueSource(strings = {"blocking-queue", "agrona-mpsc"})
    void aMailboxDeliversInOrderAndEndsWithTheMarker(String variant) throws Exception {
        Mailbox mailbox = LineRun.mailboxFor(variant);
        Scan one = new Scan(0, 1, 10, 20, "000000000000000001", 990);
        Scan two = new Scan(1, 2, 11, 21, "000000000000000002", 990);
        assertTrue(mailbox.offer(one));
        assertTrue(mailbox.offer(two));
        assertTrue(mailbox.offer(Scan.END));
        assertSame(one, mailbox.take());
        assertSame(two, mailbox.take());
        assertSame(Scan.END, mailbox.take());
    }

    @Test
    void variantNamesAreTheDocumentedOnes() {
        assertThrows(IllegalArgumentException.class, () -> LineRun.mailboxFor("queue"));
        assertThrows(IllegalArgumentException.class, () -> ClaimRun.claimFor("lock"));
        assertThrows(IllegalArgumentException.class, () -> SeqlockRun.cellFor("seqlock"));
    }

    @Test
    void cpuListsParse() {
        assertEquals(List.of(0, 2, 4), Placement.parseCpus("0,2,4"));
        assertThrows(IllegalArgumentException.class, () -> Placement.parseCpus("0,x"));
    }

    @Test
    void bothJcstressTestsAreRegisteredByTheirProcessor() throws Exception {
        try (var list = getClass().getClassLoader().getResourceAsStream("META-INF/TestList")) {
            String text = new String(list.readAllBytes(), StandardCharsets.UTF_8);
            assertTrue(text.contains(StoreBufferVolatile.class.getName()), text);
            assertTrue(text.contains(StoreBufferAcquireRelease.class.getName()), text);
        }
    }
}
