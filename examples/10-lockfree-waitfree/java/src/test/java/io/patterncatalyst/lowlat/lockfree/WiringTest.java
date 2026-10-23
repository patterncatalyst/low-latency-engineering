package io.patterncatalyst.lowlat.lockfree;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import net.openhft.affinity.Affinity;
import org.junit.jupiter.api.Test;

class WiringTest {
    @Test
    void agronaJmhAndAffinityResolve() {
        final Wiring wiring = new Wiring();
        assertEquals(0L, wiring.claim());
        assertEquals(1L, wiring.claim());
        assertTrue(Affinity.getCpu() >= -1, "Affinity loads and answers");
    }

    @Test
    void jcstressTestIsRegisteredByItsProcessor() throws Exception {
        try (var list = getClass().getClassLoader().getResourceAsStream("META-INF/TestList")) {
            final String text = new String(list.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
            assertTrue(text.contains(WiringLitmus.class.getName()), text);
        }
    }
}
