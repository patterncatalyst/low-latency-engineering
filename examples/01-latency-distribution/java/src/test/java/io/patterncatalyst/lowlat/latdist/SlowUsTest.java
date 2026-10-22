package io.patterncatalyst.lowlat.latdist;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class SlowUsTest {

    @Test
    void defaultsAndPassesTheRestThrough() {
        Latdist.SlowUs s = Latdist.SlowUs.split(new String[] {"--variant", "bimodal-1pct"});
        assertEquals(2000, s.micros());
        assertEquals(List.of("--variant", "bimodal-1pct"), s.rest());
    }

    @Test
    void takesTheFlagOutOfTheRest() {
        Latdist.SlowUs s = Latdist.SlowUs.split(new String[] {"--slow-us", "500", "--expect", "10"});
        assertEquals(500, s.micros());
        assertEquals(List.of("--expect", "10"), s.rest());
    }

    @ParameterizedTest
    @ValueSource(strings = {"0", "-1"})
    void rejectsNonPositive(String value) {
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class,
                () -> Latdist.SlowUs.split(new String[] {"--slow-us", value}));
        assertEquals("--slow-us must be > 0", e.getMessage());
    }

    @Test
    void rejectsNonNumeric() {
        assertThrows(NumberFormatException.class, () -> Latdist.SlowUs.split(new String[] {"--slow-us", "abc"}));
    }
}
