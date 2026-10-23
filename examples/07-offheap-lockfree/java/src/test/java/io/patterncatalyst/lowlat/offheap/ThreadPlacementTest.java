package io.patterncatalyst.lowlat.offheap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

/** The placement seam: names, and the isolation check that runs before any thread exists. */
class ThreadPlacementTest {

    @Test
    void namesResolveToTheirPlacements() {
        assertSame(ThreadPlacement.UNPINNED, ThreadPlacement.named("unpinned"));
        assertSame(ThreadPlacement.PINNED_ISOLATED, ThreadPlacement.named("pinned-isolated"));
        assertEquals("pinned-isolated", ThreadPlacement.PINNED_ISOLATED.label());
        assertThrows(IllegalArgumentException.class, () -> ThreadPlacement.named("pinned"));
    }

    @ParameterizedTest
    @CsvSource(delimiter = '|', value = {
        "ro root=x isolcpus=3 nohz_full=3 | true",
        "isolcpus=2-5 | true",
        "isolcpus=domain,managed_irq,1,3 | true",
        "isolcpus=2 nohz_full=3 rcu_nocbs=3 | false",
        "ro quiet | false"})
    void isolcpusIsReadFromListsRangesAndFlags(String line, boolean isolated) {
        assertEquals(isolated, ThreadPlacement.isolates(line, 3));
    }

    @Test
    void pinnedIsolatedRefusesAKernelWithoutIsolcpus(@TempDir Path dir) throws IOException {
        Path cmdline = Files.writeString(dir.resolve("cmdline"), "BOOT_IMAGE=x ro quiet\n");
        IllegalStateException e = assertThrows(IllegalStateException.class,
                () -> ThreadPlacement.requireIsolatedCpu(cmdline, 3));
        assertTrue(e.getMessage().contains("isolcpus=3"), e.getMessage());
    }
}
