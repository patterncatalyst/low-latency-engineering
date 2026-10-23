package io.patterncatalyst.lowlat.measure;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class RuntimeInfoTest {

    @ParameterizedTest
    @ValueSource(strings = {"-XX:+UseSerialGC", "-XX:+UseParallelGC", "-XX:+UseG1GC", "-XX:+UseZGC",
        "-XX:+UseShenandoahGC", "-XX:+UseEpsilonGC", "-XX:ShenandoahGCMode=generational", "-Xms256m",
        "-Xmx1g", "-Xmn64m", "-XX:+AlwaysPreTouch", "-XX:+UseTransparentHugePages", "-XX:+UseLargePages",
        "-XX:MaxGCPauseMillis=5"})
    void collectorHeapAndMemoryBackingFlagsAreKept(String flag) {
        assertTrue(RuntimeInfo.isGcFlag(flag), flag);
    }

    @ParameterizedTest
    @ValueSource(strings = {"-XX:+UseCompactObjectHeaders", "-XX:+UseStringDeduplication-not-a-gc-switch",
        "-XX:+ZGenerational", "-XX:-ZGenerational", "-XX:+UseNUMA", "-Dfoo=bar", "-XX:+UnlockExperimentalVMOptions"})
    void unrelatedAndObsoleteFlagsAreNot(String flag) {
        assertFalse(RuntimeInfo.isGcFlag(flag), flag);
    }

    @Test
    @SuppressWarnings("unchecked") // the gc value is a Map<String, Object> by construction
    void extraGcEntriesLandInsideTheGcObject() {
        Map<String, Object> gc = (Map<String, Object>) RuntimeInfo.jvm(Map.of("old_gen_used_bytes", 42L)).get("gc");
        assertEquals(42L, gc.get("old_gen_used_bytes"));
    }
}
