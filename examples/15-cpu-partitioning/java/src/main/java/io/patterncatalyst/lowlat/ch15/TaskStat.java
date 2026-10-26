package io.patterncatalyst.lowlat.ch15;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.TreeMap;
import java.util.stream.Stream;

/**
 * The CPU each thread of this JVM last ran on, read from {@code /proc/self/task/<tid>/stat} (field 39,
 * "processor"). Counting which JVM threads sit on the isolated CPUs is how the chapter shows what
 * {@code taskset} on the whole JVM does to its helper threads.
 */
public final class TaskStat {

    private TaskStat() {
    }

    /**
     * Field 39 of a stat line. The command name (field 2) sits in parentheses and may itself contain spaces
     * and parentheses, so the fields are counted after the LAST ')'.
     */
    static int lastCpu(String statLine) {
        int close = statLine.lastIndexOf(')');
        if (close < 0) {
            throw new IllegalArgumentException("no command name in stat line: " + statLine);
        }
        String[] afterComm = statLine.substring(close + 1).strip().split("\\s+");
        // afterComm[0] is field 3 (state), so field 39 is afterComm[36].
        if (afterComm.length < 37) {
            throw new IllegalArgumentException("stat line has only " + (afterComm.length + 2) + " fields");
        }
        return Integer.parseInt(afterComm[36]);
    }

    /** The thread name (field 2) of a stat line, without the parentheses. */
    static String comm(String statLine) {
        int open = statLine.indexOf('(');
        int close = statLine.lastIndexOf(')');
        if (open < 0 || close < open) {
            throw new IllegalArgumentException("no command name in stat line: " + statLine);
        }
        return statLine.substring(open + 1, close);
    }

    /** Thread name to last-run CPU for every thread of this process, keyed "name-tid" so names need not be unique. */
    public static Map<String, Integer> sample(Path taskDir) throws IOException {
        Map<String, Integer> cpus = new TreeMap<>();
        try (Stream<Path> tasks = Files.list(taskDir)) {
            for (Path task : (Iterable<Path>) tasks::iterator) {
                try {
                    String line = Files.readString(task.resolve("stat"));
                    cpus.put(comm(line) + "-" + task.getFileName(), lastCpu(line));
                } catch (IOException gone) {
                    // the thread exited between the listing and the read
                }
            }
        }
        return cpus;
    }

    /** {@link #sample} for the running JVM. */
    public static Map<String, Integer> sampleSelf() throws IOException {
        return sample(Path.of("/proc/self/task"));
    }
}
