package io.patterncatalyst.lowlat.eliminating;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import net.openhft.affinity.Affinity;
import net.openhft.affinity.AffinityLock;

/**
 * Thread placement as an experiment control: pin the calling thread to one logical CPU with OpenHFT's
 * {@link AffinityLock} (a thin layer over {@code sched_setaffinity}) and print where it landed, so verify.sh can
 * check {@code /proc/<pid>/task/<tid>/stat}. Unprivileged and confined to our own threads; it is not isolation.
 */
public final class Placement {

    /** System property naming the CPU the benchmark thread pins to (set by verify.sh; unset means unpinned). */
    public static final String CPU_PROPERTY = "lowlat.cpu";

    private Placement() {
    }

    /** The CPU named by {@value #CPU_PROPERTY}, or -1. */
    public static int configuredCpu() {
        return Integer.getInteger(CPU_PROPERTY, -1);
    }

    /**
     * Pins the calling thread to {@code cpu} and checks that it took: OpenHFT declines to bind CPU 0 ("CPU not
     * available") and would leave the thread wherever the scheduler puts it, so pick another CPU. The caller closes
     * the lock.
     */
    public static AffinityLock acquire(int cpu) {
        AffinityLock lock = AffinityLock.acquireLock(cpu);
        if (Affinity.getCpu() != cpu) {
            lock.close();
            throw new IllegalStateException("could not pin the thread to CPU " + cpu + " (it runs on " + Affinity.getCpu() + ")");
        }
        return lock;
    }

    /** {@link #acquire} and print the placement line. */
    public static AffinityLock pin(int cpu, String role) {
        AffinityLock lock = acquire(cpu);
        announce(cpu, role);
        return lock;
    }

    /** The benchmark threads' variant: pin only when {@value #CPU_PROPERTY} is set; null otherwise. */
    public static AffinityLock pinConfigured(String role) {
        int cpu = configuredCpu();
        return cpu < 0 ? null : pin(cpu, role);
    }

    /** Environment variable naming a file the placement lines are appended to (perf holds back stdout until exit). */
    public static final String FILE_ENV = "LOWLAT_PLACEMENT_FILE";

    /** {@code placement pid=P tid=T cpu=C role=R} for the calling thread: the line verify.sh reads. */
    public static void announce(int cpu, String role) {
        announce(line(cpu, role));
    }

    /** The placement line of the calling thread. */
    public static String line(int cpu, String role) {
        return "placement pid=%d tid=%d cpu=%d role=%s".formatted(ProcessHandle.current().pid(), Affinity.getThreadId(), cpu, role);
    }

    /** Prints the line and appends it to {@value #FILE_ENV} when that is set. */
    public static synchronized void announce(String line) {
        System.out.println(line);
        System.out.flush();
        String file = System.getenv(FILE_ENV);
        if (file != null) {
            try {
                Files.writeString(Path.of(file), line + System.lineSeparator(), StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
        }
    }
}
