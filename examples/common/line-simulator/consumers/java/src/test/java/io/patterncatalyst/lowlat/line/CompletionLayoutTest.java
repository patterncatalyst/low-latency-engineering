package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;
import org.openjdk.jol.info.ClassLayout;

/**
 * The seq the receive thread writes per parcel must not share a cache line with the fields the
 * owner thread writes per parcel (the Ch7 hand-off would otherwise ping-pong a line).
 */
class CompletionLayoutTest {

    private static final int LINE = 64;

    @Test
    void seqIsPaddedOnBothSidesByAFullCacheLine() {
        ClassLayout layout = ClassLayout.parseClass(Completion.SeqCell.class);
        long value = layout.fields().stream()
                .filter(f -> f.name().equals("value"))
                .findFirst()
                .orElseThrow()
                .offset();
        assertTrue(value >= LINE, "value at " + value + " has less than a line before it");
        assertTrue(layout.instanceSize() - (value + Long.BYTES) >= LINE,
                "less than a line after value in a " + layout.instanceSize() + " byte object");
    }
}
