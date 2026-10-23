package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;

class ReportGateTest {

    @Test
    void onlyTheFirstClaimWins() {
        ReportGate gate = new ReportGate();
        assertTrue(gate.claim());
        assertFalse(gate.claim());
    }

    @Test
    void aLoserWaitsUntilTheWinnerIsDone() throws Exception {
        ReportGate gate = new ReportGate();
        assertTrue(gate.claim());
        AtomicBoolean returned = new AtomicBoolean();
        CountDownLatch finished = new CountDownLatch(1);
        Thread loser = Thread.ofPlatform().start(() -> {
            try {
                assertFalse(gate.claim());
                returned.set(gate.awaitDone(30, TimeUnit.SECONDS));
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } finally {
                finished.countDown();
            }
        });
        assertFalse(finished.await(200, TimeUnit.MILLISECONDS), "the loser must still be waiting");
        gate.done();
        assertTrue(finished.await(10, TimeUnit.SECONDS));
        loser.join();
        assertTrue(returned.get());
    }

    @Test
    void failureIsVisibleToTheLoser() throws Exception {
        ReportGate gate = new ReportGate();
        assertTrue(gate.claim());
        gate.failed();
        assertTrue(gate.awaitDone(1, TimeUnit.SECONDS));
        assertTrue(gate.hasFailed());
    }

    @Test
    void awaitIsBounded() throws Exception {
        ReportGate gate = new ReportGate();
        assertTrue(gate.claim());
        assertFalse(gate.awaitDone(50, TimeUnit.MILLISECONDS));
    }
}
