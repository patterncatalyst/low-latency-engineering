package io.patterncatalyst.lowlat.lockfree;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import java.util.Collections;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Deterministic checks of the claim run: each variant hands out every sequence exactly once. */
class ClaimRunTest {

    private static ClaimRun.Result run(String variant, boolean stalled) throws Exception {
        int producers = 4;
        long perThread = 20_000;
        return ClaimRun.run(variant, producers, perThread, 256, stalled, stalled ? producers * perThread / 2 : -1,
                Collections.nCopies(producers + 1, -1), new Placement.Gate(producers + 1, 0, false),
                LatencyRecorder.singleThreaded(ClaimRun.EXAMPLE, variant), LatencyRecorder.singleThreaded(ClaimRun.EXAMPLE, variant));
    }

    @ParameterizedTest
    @ValueSource(strings = {"mutex", "cas-loop", "fetch-add"})
    void everyVariantClaimsEachSequenceExactlyOnce(String variant) throws Exception {
        ClaimRun.Result result = run(variant, false);
        assertEquals(80_000, result.claims());
        assertEquals(0, result.lostOrDuplicated());
        assertEquals(0, result.payloadMismatches());
    }

    @Test
    void fetchAddIsOneStepPerClaim() throws Exception {
        ClaimRun.Result result = run("fetch-add", false);
        assertEquals(result.claims(), result.steps());
        assertEquals(0, result.casFailures());
    }

    @Test
    void casLoopCountsItsFailedAttempts() throws Exception {
        ClaimRun.Result result = run("cas-loop", false);
        assertEquals(result.claims() + result.casFailures(), result.steps());
    }

    @Test
    void theConsumerWaitsForTheStalledProducer() throws Exception {
        ClaimRun.Result result = run("fetch-add", true);
        assertEquals(0, result.lostOrDuplicated());
        assertTrue(result.consumerWaitAtStalledNs() > 0, "the consumer found the stalled slot unpublished");
    }
}
