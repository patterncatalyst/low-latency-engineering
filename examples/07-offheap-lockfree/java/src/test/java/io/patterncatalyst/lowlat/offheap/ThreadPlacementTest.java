package io.patterncatalyst.lowlat.offheap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/** The placement seam: names, and the isolation check that runs before any thread exists. */
class ThreadPlacementTest {

    @Test
    void namesResolveToTheirPlacements() {
        assertSame(ThreadPlacement.UNPINNED, ThreadPlacement.named("unpinned"));
        assertSame(ThreadPlacement.PINNED_ISOLATED, ThreadPlacement.named("pinned-isolated"));
        assertEquals("pinned-isolated", ThreadPlacement.PINNED_ISOLATED.label());
        assertThrows(IllegalArgumentException.class, () -> ThreadPlacement.named("pinned"));
    }

    @Test
    void isolcpusIsReadFromListsRangesAndFlags() {
        assertTrue(ThreadPlacement.isolates("ro root=x isolcpus=3 nohz_full=3", 3));
        assertTrue(ThreadPlacement.isolates("isolcpus=2-5", 3));
        assertTrue(ThreadPlacement.isolates("isolcpus=domain,managed_irq,1,3", 3));
        assertFalse(ThreadPlacement.isolates("isolcpus=2 nohz_full=3 rcu_nocbs=3", 3));
        assertFalse(ThreadPlacement.isolates("ro quiet", 3));
    }

    @Test
    void pinnedIsolatedRefusesAKernelWithoutIsolcpus(@TempDir Path dir) throws IOException {
        Path cmdline = Files.writeString(dir.resolve("cmdline"), "BOOT_IMAGE=x ro quiet\n");
        IllegalStateException e = assertThrows(IllegalStateException.class,
                () -> ThreadPlacement.requireIsolatedCpu(cmdline, 3));
        assertTrue(e.getMessage().contains("isolcpus=3"), e.getMessage());
    }
}
