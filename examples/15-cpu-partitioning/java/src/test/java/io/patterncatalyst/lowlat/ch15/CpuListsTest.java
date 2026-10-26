package io.patterncatalyst.lowlat.ch15;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class CpuListsTest {

    @Test
    void parsesRangesAndSingles() {
        var cpus = CpuLists.parse("0,2-3,7");
        assertEquals(4, cpus.cardinality());
        assertTrue(cpus.get(0) && cpus.get(2) && cpus.get(3) && cpus.get(7));
    }

    @Test
    void anEmptyListIsNoCpus() {
        assertTrue(CpuLists.parse("\n").isEmpty());  // /sys/devices/system/cpu/isolated is empty without isolation
    }

    @Test
    void formatIsTheInverseOfParse() {
        assertEquals("0,2-3,7", CpuLists.format(CpuLists.parse("7,0,3,2")));
        assertEquals("", CpuLists.format(CpuLists.parse("")));
        assertEquals("2-3", CpuLists.format(CpuLists.parse("2-3")));
    }

    @Test
    void rejectsMalformedItems() {
        assertThrows(IllegalArgumentException.class, () -> CpuLists.parse("a"));
        assertThrows(IllegalArgumentException.class, () -> CpuLists.parse("3-2"));
        assertThrows(IllegalArgumentException.class, () -> CpuLists.parse("-1"));
    }
}
