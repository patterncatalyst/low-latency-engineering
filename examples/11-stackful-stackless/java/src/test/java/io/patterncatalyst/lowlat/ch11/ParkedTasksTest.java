package io.patterncatalyst.lowlat.ch11;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class ParkedTasksTest {

    @Test
    void everyVirtualThreadRuns() throws InterruptedException {
        assertEquals(100, ParkedTasks.runOnVirtualThreads(100));
    }
}
