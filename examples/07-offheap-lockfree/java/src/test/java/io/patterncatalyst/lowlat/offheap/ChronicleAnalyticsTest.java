package io.patterncatalyst.lowlat.offheap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.lang.management.ManagementFactory;
import org.junit.jupiter.api.Test;

/** Chronicle's usage analytics are off in the forked test JVM, by the argLine and by the guard. */
class ChronicleAnalyticsTest {

    @Test
    void forkedJvmWasStartedWithTheSwitch() {
        assertTrue(ManagementFactory.getRuntimeMXBean().getInputArguments()
                        .contains("-D" + ChronicleAnalytics.PROPERTY + "=true"),
                "surefire argLine in pom.xml carries -Dchronicle.analytics.disable=true");
        assertEquals("true", System.getProperty("chronicle.analytics.disable"));
    }

    @Test
    void guardSetsTheSwitch() {
        String before = System.getProperty(ChronicleAnalytics.PROPERTY);
        try {
            System.clearProperty(ChronicleAnalytics.PROPERTY);
            ChronicleAnalytics.disable();
            assertEquals("true", System.getProperty("chronicle.analytics.disable"));
        } finally {
            if (before != null) {
                System.setProperty(ChronicleAnalytics.PROPERTY, before);
            }
        }
    }
}
