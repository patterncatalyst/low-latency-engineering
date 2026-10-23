package io.patterncatalyst.lowlat.jvmcosts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

class CostsTest {

    @Test
    void warmUpIsSplitOffAndTheRestPassesThrough() {
        Costs.Args split = Costs.Args.split(new String[] {"--variant", "warmed", "--warm-up", "20000", "--window", "2000"});
        assertEquals(20_000, split.warmUp());
        assertEquals(List.of("--variant", "warmed", "--window", "2000"), split.rest());
        assertEquals(0, Costs.Args.split(new String[] {"--variant", "unwarmed"}).warmUp());
    }

    @Test
    void aNegativeWarmUpIsRefused() {
        assertThrows(IllegalArgumentException.class, () -> Costs.Args.split(new String[] {"--warm-up", "-1"}));
    }

    @Test
    void noAotBlockWithoutAnAotCacheFlag() {
        assertNull(Costs.aotFromFlags(), "the test JVM runs without -XX:AOTCache");
    }

    @Test
    void theJmhProcessorRan() {
        assertNotNull(CostsTest.class.getResource("/META-INF/BenchmarkList"), "JMH annotation processor ran");
    }

    @Test
    void theWarmUpReplayHandlesWhatItSends() throws Exception {
        WarmUp.Result result = WarmUp.replay(2_000);
        assertEquals(2_000, result.sent());
        assertEquals(2_000, result.handled() + result.dropped(), "every parcel is either handled or counted missing");
        assertTrue(result.handled() > 1_000, "most of the replay arrives: " + result);
    }

    @Test
    void theCompilerQuietWaitReturns() throws InterruptedException {
        assertTrue(WarmUp.awaitCompilerQuiet() >= 0);
    }
}
