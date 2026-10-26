package io.patterncatalyst.lowlat.ch14;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;

/** Nothing here needs root or SCHED_FIFO: the policy is only read, and a bad priority is rejected before the call. */
class SchedTest {

    @Test
    void theJnaMappingLoads() {
        assertTrue(Libc.INSTANCE != null);
    }

    @Test
    void aTestThreadStartsAsSchedOther() {
        assertEquals(Libc.SCHED_OTHER, Sched.policy());
    }

    @Test
    void tidIsTheTaskDirectoryOfThisThread() throws IOException {
        // /proc/thread-self points at "<tgid>/task/<tid>".
        String target = Files.readSymbolicLink(Path.of("/proc/thread-self")).toString();
        assertTrue(target.endsWith("/task/" + Sched.tid()), target + " vs tid " + Sched.tid());
    }

    @Test
    void pinMovesOnlyTheCallingThread() throws Exception {
        // The first CPU this test may run on: pinning to it needs no privilege and is a no-op on a one-CPU box.
        String allowed = Files.readAllLines(Path.of("/proc/self/status")).stream()
                .filter(l -> l.startsWith("Cpus_allowed_list:")).findFirst().orElseThrow();
        int cpu = Integer.parseInt(allowed.substring(allowed.indexOf(':') + 1).trim().split("[,-]")[0]);
        String[] seen = new String[1];
        Thread t = new Thread(() -> {
            try {
                Sched.pin(cpu);
                seen[0] = Files.readAllLines(Path.of("/proc/thread-self/status")).stream()
                        .filter(l -> l.startsWith("Cpus_allowed_list:")).findFirst().orElseThrow();
            } catch (IOException e) {
                throw new java.io.UncheckedIOException(e);
            }
        });
        t.start();
        t.join();
        assertEquals(cpu, Integer.parseInt(seen[0].substring(seen[0].indexOf(':') + 1).trim()));
    }

    @Test
    void anOutOfRangeCpuIsRefusedBeforeTheSystemCall() {
        assertThrows(IllegalArgumentException.class, () -> Sched.pin(-1));
        assertThrows(IllegalArgumentException.class, () -> Sched.pin(1024));
    }

    @Test
    void anOutOfRangePriorityIsRefusedBeforeTheSystemCall() {
        assertThrows(IllegalArgumentException.class, () -> Sched.fifo(0));
        assertThrows(IllegalArgumentException.class, () -> Sched.fifo(100));
    }
}
