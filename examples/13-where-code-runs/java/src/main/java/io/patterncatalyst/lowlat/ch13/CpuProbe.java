package io.patterncatalyst.lowlat.ch13;

import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;

import com.sun.management.HotSpotDiagnosticMXBean;
import jdk.management.VirtualThreadSchedulerMXBean;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.SerializationFeature;
import tools.jackson.databind.json.JsonMapper;

/**
 * What the JVM thinks it has: the processor count it ergonomics-sizes everything from, the virtual-thread
 * scheduler's parallelism, and the GC thread counts. The JVM reads a container's CPU quota (ceil of
 * quota over period) and its cpuset (through the affinity mask) when it starts, so the same jar prints
 * different numbers in the guest, under {@code --cpus=2} and under {@code --cpuset-cpus=2,3}. The virtual-thread
 * scheduler's parallelism comes from {@code VirtualThreadSchedulerMXBean}; the carriers that ran a spinning load are
 * counted as a cross-check.
 *
 * <pre>
 *   java -cp where-code-runs-java.jar io.patterncatalyst.lowlat.ch13.CpuProbe [--out FILE]
 * </pre>
 *
 * Every value is exact (a count the JVM or the kernel reports), none is a measurement of time.
 */
public final class CpuProbe {

    private static final long SPIN_NANOS = 100_000_000L;

    /** Written by the spinning virtual threads so the busy loop has an effect the JIT cannot drop. */
    private static volatile long sink;

    private CpuProbe() {}

    public static int availableProcessors() {
        return Runtime.getRuntime().availableProcessors();
    }

    /**
     * The number of distinct carrier threads that ran virtual threads, counted by starting more spinning
     * virtual threads than there are processors. A carrier is a platform thread of the scheduler's pool, which
     * starts one per unit of parallelism as work arrives, so with enough concurrent work the count is the
     * scheduler's parallelism. The carrier is named in {@code Thread.toString()} after the {@code @}. This is the
     * cross-check; the parallelism itself is read from the scheduler's MXBean.
     */
    public static int observedCarriers(int processors) {
        Set<String> carriers = ConcurrentHashMap.newKeySet();
        int tasks = Math.max(8, processors * 4);
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            for (int i = 0; i < tasks; i++) {
                executor.submit(() -> {
                    String name = Thread.currentThread().toString();
                    int at = name.indexOf('@');
                    carriers.add(at < 0 ? name : name.substring(at + 1));
                    long deadline = System.nanoTime() + SPIN_NANOS;
                    long x = 0;
                    while (System.nanoTime() < deadline) {
                        x++;
                        Thread.onSpinWait();
                    }
                    sink = x;
                });
            }
        }
        return carriers.size();
    }

    private static VirtualThreadSchedulerMXBean scheduler() {
        return ManagementFactory.getPlatformMXBean(VirtualThreadSchedulerMXBean.class);
    }

    /** A HotSpot flag's value as a number, or -1 when the flag does not exist in this VM. */
    static long vmOption(String name) {
        try {
            return Long.parseLong(ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class).getVMOption(name).getValue());
        } catch (IllegalArgumentException e) {
            return -1;
        }
    }

    public static Map<String, Object> probe() {
        int processors = availableProcessors();
        Map<String, Object> java = new LinkedHashMap<>();
        java.put("available_processors", processors);
        java.put("virtual_thread_parallelism", scheduler().getParallelism());
        java.put("virtual_thread_carriers_observed", observedCarriers(processors));
        java.put("virtual_thread_pool_size_after_spin", scheduler().getPoolSize());
        java.put("parallel_gc_threads", vmOption("ParallelGCThreads"));
        java.put("conc_gc_threads", vmOption("ConcGCThreads"));
        java.put("collectors", ManagementFactory.getGarbageCollectorMXBeans().stream().map(b -> b.getName()).toList());
        java.put("max_heap_bytes", Runtime.getRuntime().maxMemory());
        java.put("version", Runtime.version().toString());
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("schema", "lowlat-place-probe/1");
        out.put("example", "13-where-code-runs");
        out.put("language", "java");
        out.put("java", java);
        return out;
    }

    public static void main(String[] args) throws IOException {
        String json = mapper().writeValueAsString(probe()) + System.lineSeparator();
        if (args.length == 2 && args[0].equals("--out")) {
            Files.writeString(Path.of(args[1]), json);
        } else if (args.length == 0) {
            System.out.print(json);
        } else {
            System.err.println("usage: CpuProbe [--out FILE]");
            System.exit(2);
        }
    }

    static ObjectMapper mapper() {
        return JsonMapper.builder().enable(SerializationFeature.INDENT_OUTPUT).build();
    }
}
