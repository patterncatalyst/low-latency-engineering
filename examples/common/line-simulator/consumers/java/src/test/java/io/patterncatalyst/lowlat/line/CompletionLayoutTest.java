package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;
import org.openjdk.jol.info.ClassLayout;

/**
 * The seq the receive thread writes per parcel must not share a cache line, or an adjacent-line
 * prefetch pair, with the fields the owner thread writes per parcel (the Ch7 hand-off would
 * otherwise ping-pong a line). Padding is 128 bytes: the width of the JDK's {@code @Contended}.
 */
class CompletionLayoutTest {

    private static final int PAIR = 128;

    @Test
    void seqIsPaddedOnBothSidesByALinePair() {
        assertPadded(Completion.SeqCell.class, List.of("value"));
    }

    @Test
    void ownerFieldsArePaddedOnBothSidesByALinePair() {
        assertPadded(Completion.DoneCell.class, List.of("count", "firstDoneNs", "lastDoneNs"));
    }

    @Test
    void completionHoldsOnlyReferencesToTheCells() {
        // The receive thread reads the SeqCell reference once; the owner-written counters are not
        // fields of Completion itself.
        List<String> names = ClassLayout.parseClass(Completion.class).fields().stream()
                .map(f -> f.name())
                .toList();
        assertTrue(names.containsAll(List.of("seq", "done")), names.toString());
        assertTrue(names.stream().noneMatch(n -> n.equals("count") || n.endsWith("DoneNs")), names.toString());
    }

    private static void assertPadded(Class<?> cell, List<String> fields) {
        ClassLayout layout = ClassLayout.parseClass(cell);
        long first = Long.MAX_VALUE;
        long end = 0;
        for (var f : layout.fields()) {
            if (fields.contains(f.name())) {
                first = Math.min(first, f.offset());
                end = Math.max(end, f.offset() + f.size());
            }
        }
        assertTrue(first >= PAIR, "fields at " + first + " have less than " + PAIR + " bytes before them");
        assertTrue(layout.instanceSize() - end >= PAIR,
                "less than " + PAIR + " bytes after the fields in a " + layout.instanceSize() + " byte object");
    }
}
