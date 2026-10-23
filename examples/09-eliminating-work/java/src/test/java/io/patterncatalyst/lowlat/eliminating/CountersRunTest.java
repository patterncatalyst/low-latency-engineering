package io.patterncatalyst.lowlat.eliminating;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.util.List;
import org.junit.jupiter.api.Test;

/** The counters command line: a bad one prints usage and exits 2 instead of throwing. */
class CountersRunTest {

    private static int runCapturingStderr(ByteArrayOutputStream err, List<String> args) throws IOException, InterruptedException {
        PrintStream saved = System.err;
        System.setErr(new PrintStream(err, true));
        try {
            return CountersRun.run(args);
        } finally {
            System.setErr(saved);
        }
    }

    @Test
    void missingOptionValueIsAUsageError() throws Exception {
        for (String option : List.of("--variant", "--cpus", "--cameras", "--batches", "--hold-ms", "--increment", "--out")) {
            ByteArrayOutputStream err = new ByteArrayOutputStream();
            assertEquals(2, runCapturingStderr(err, List.of(option)), option);
            String text = err.toString();
            assertTrue(text.contains(option + " needs a value"), text);
            assertTrue(text.contains("usage: counters"), text);
        }
    }

    @Test
    void unknownOptionIsAUsageError() throws Exception {
        assertEquals(2, runCapturingStderr(new ByteArrayOutputStream(), List.of("--bogus")));
    }
}
