package io.patterncatalyst.lowlat.gctails;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;

class OptionsTest {

    @Test
    void defaultsAreTheDocumentedWorkload() {
        Options o = Options.parse(new String[0]);
        assertEquals(Settings.defaults(), o.settings());
        assertEquals(30_000, o.warmUp());
        assertNull(o.jfr());
        assertFalse(o.probe());
    }

    @Test
    void ownFlagsAreSplitFromTheCommonOnes() {
        Options o = Options.parse(new String[] {"--live-set-mb", "512", "--bind", "127.0.0.1:1", "--jfr", "/tmp/x.jfr",
                "--alloc-mb-per-s", "100", "--probe", "--variant", "zgc"});
        assertEquals(512L << 20, o.settings().liveSetBytes());
        assertEquals(100L << 20, o.settings().allocBytesPerSecond());
        assertEquals(Path.of("/tmp/x.jfr"), o.jfr());
        assertTrue(o.probe());
        assertEquals(List.of("--bind", "127.0.0.1:1", "--variant", "zgc"), o.rest());
    }

    @Test
    void badNumbersAreRejectedWithTheOption() {
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class,
                () -> Options.parse(new String[] {"--rate", "fast"}));
        assertTrue(e.getMessage().contains("--rate"));
        assertThrows(IllegalArgumentException.class, () -> Options.parse(new String[] {"--jfr"}));
    }
}
