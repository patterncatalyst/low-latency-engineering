package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.List;
import org.junit.jupiter.api.Test;

class ConfigTest {

    @Test
    void defaults() {
        Config c = Config.parse(List.of());
        assertEquals("127.0.0.1", c.bindHost());
        assertEquals(47000, c.bindPort());
        assertEquals(4 << 20, c.rcvbuf());
        assertEquals(2000, c.idleTimeoutMs());
        assertEquals("00-line-consumer", c.example());
        assertEquals("baseline", c.variant());
    }

    @Test
    void parsesAllOptions() {
        Config c = Config.parse(List.of("--bind", "0.0.0.0:47103", "--rcvbuf", "1024", "--expect", "10",
                "--idle-timeout-ms", "50", "--report", "r.json", "--example", "x", "--variant", "y"));
        assertEquals(47103, c.bindPort());
        assertEquals(10, c.expect());
        assertEquals("y", c.variant());
    }

    @Test
    void rejectsBadInput() {
        assertThrows(IllegalArgumentException.class, () -> Config.parse(List.of("--bind", "nope")));
        assertThrows(IllegalArgumentException.class, () -> Config.parse(List.of("--expect", "-1")));
        assertThrows(IllegalArgumentException.class, () -> Config.parse(List.of("--wat", "1")));
        assertThrows(Config.HelpRequested.class, () -> Config.parse(List.of("--help")));
    }
}
