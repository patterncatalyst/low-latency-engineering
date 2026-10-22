package io.patterncatalyst.lowlat.measure;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

class RuntimeInfoTest {

    @Test
    void collectorHeapAndMemoryBackingFlagsAreKept() {
        for (String flag : List.of("-XX:+UseSerialGC", "-XX:+UseParallelGC", "-XX:+UseG1GC", "-XX:+UseZGC",
                "-XX:+UseShenandoahGC", "-XX:+UseEpsilonGC", "-XX:ShenandoahGCMode=generational", "-Xms256m",
                "-Xmx1g", "-Xmn64m", "-XX:+AlwaysPreTouch", "-XX:+UseTransparentHugePages", "-XX:+UseLargePages",
                "-XX:MaxGCPauseMillis=5")) {
            assertTrue(RuntimeInfo.isGcFlag(flag), flag);
        }
    }

    @Test
    void unrelatedAndObsoleteFlagsAreNot() {
        for (String flag : List.of("-XX:+UseCompactObjectHeaders", "-XX:+UseStringDeduplication-not-a-gc-switch",
                "-XX:+ZGenerational", "-XX:-ZGenerational", "-XX:+UseNUMA", "-Dfoo=bar", "-XX:+UnlockExperimentalVMOptions")) {
            assertFalse(RuntimeInfo.isGcFlag(flag), flag);
        }
    }
}
