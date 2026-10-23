package io.patterncatalyst.lowlat.eliminating;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import net.openhft.affinity.Affinity;
import org.junit.jupiter.api.Test;

class WiringTest {
    @Test
    void agronaJolJmhAndAffinityResolve() {
        assertEquals(42L, new Wiring().putGet());
        assertTrue(Wiring.instanceSize(Object.class) >= 8);
        assertTrue(Affinity.getCpu() >= -1, "Affinity loads and answers");
    }
}
