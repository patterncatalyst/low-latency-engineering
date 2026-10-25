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
    void anOutOfRangePriorityIsRefusedBeforeTheSystemCall() {
        assertThrows(IllegalArgumentException.class, () -> Sched.fifo(0));
        assertThrows(IllegalArgumentException.class, () -> Sched.fifo(100));
    }
}
