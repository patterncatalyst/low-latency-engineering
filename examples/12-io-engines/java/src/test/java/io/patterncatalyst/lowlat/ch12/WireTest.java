package io.patterncatalyst.lowlat.ch12;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.patterncatalyst.lowlat.line.Lanes;
import java.nio.ByteBuffer;
import org.junit.jupiter.api.Test;

class WireTest {

    @Test
    void aRecordRoundTripsItsFields() {
        ByteBuffer buf = Wire.encode(Wire.newBuffer(), 42, 1_234_567_890L, "003400001234567890");
        assertTrue(Wire.valid(buf));
        assertEquals(42, Wire.seq(buf));
        assertEquals(1_234_567_890L, Wire.intendedEmitNs(buf));
    }

    @Test
    void theLaneDecodedInPlaceMatchesTheLineConsumer() {
        for (String sscc : new String[] {"003400001234567890", "003400009999999993", "100000000000000007", "000000000000000000"}) {
            ByteBuffer buf = Wire.encode(Wire.newBuffer(), 0, 0, sscc);
            assertEquals(Lanes.laneOf(sscc), Wire.lane(buf), sscc);
        }
    }

    @Test
    void aShortOrForeignDatagramIsNotAParcel() {
        ByteBuffer buf = Wire.encode(Wire.newBuffer(), 1, 1, "003400001234567890");
        buf.limit(40);
        assertFalse(Wire.valid(buf));
        ByteBuffer wrongSchema = Wire.encode(Wire.newBuffer(), 1, 1, "003400001234567890");
        wrongSchema.putShort(0, (short) 9);
        assertFalse(Wire.valid(wrongSchema));
    }

    @Test
    void aBarcodeThatIsNotDigitsIsRefused() {
        ByteBuffer buf = Wire.encode(Wire.newBuffer(), 0, 0, "00340000123456789X");
        assertThrows(IllegalArgumentException.class, () -> Wire.lane(buf));
    }

    @Test
    void theTrackerCountsNewParcelsAndTheLostOnes() {
        SeqTracker t = new SeqTracker(5);
        assertTrue(t.observe(0));
        assertTrue(t.observe(1));
        assertFalse(t.observe(1)); // a repeat
        assertTrue(t.observe(3)); // 2 is skipped
        assertFalse(t.complete());
        assertTrue(t.observe(4));
        assertTrue(t.complete());
        assertEquals(4, t.received());
        assertEquals(1, t.lost());
    }
}
