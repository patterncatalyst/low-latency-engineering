package io.patterncatalyst.lowlat.measure;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Builds the optional {@code runtime} block of a report from the running JVM. The caller
 * passes the result to {@link LatencyRecorder#writeReport(java.nio.file.Path, String, Map, Map)};
 * nothing is added to a report on its own, and callers extend the map with measured facts
 * (JIT counts, allocation per parcel, context switches).
 */
public final class RuntimeInfo {

    /**
     * The JVM input arguments {@code gc.flags} keeps: the collector selection and its mode, the
     * heap sizing and the memory-backing flags that change GC behavior. Listed one by one, not by a
     * {@code -XX:+Use} prefix, which would also capture unrelated switches such as
     * {@code UseCompactObjectHeaders}.
     */
    private static final List<String> GC_FLAG_PREFIXES = List.of(
            "-XX:+UseSerialGC", "-XX:+UseParallelGC", "-XX:+UseG1GC", "-XX:+UseZGC", "-XX:+UseShenandoahGC",
            "-XX:+UseEpsilonGC", "-XX:ShenandoahGCMode=", "-Xms", "-Xmx", "-Xmn", "-XX:MaxGCPauseMillis=",
            "-XX:+AlwaysPreTouch", "-XX:+UseTransparentHugePages", "-XX:+UseLargePages", "-Xlog:gc");

    private RuntimeInfo() {}

    /** True for a JVM argument that selects or tunes the collector or the heap. */
    static boolean isGcFlag(String argument) {
        return GC_FLAG_PREFIXES.stream().anyMatch(argument::startsWith);
    }

    /**
     * {@code gc.collectors}: the {@code GarbageCollectorMXBean} names; {@code gc.flags}: the GC-
     * and heap-related JVM input arguments. The map is mutable so the caller can add more keys.
     */
    public static Map<String, Object> jvm() {
        return jvm(Map.of());
    }

    /** As {@link #jvm()}, with {@code extraGc} entries added to the {@code gc} object after its own keys. */
    public static Map<String, Object> jvm(Map<String, ?> extraGc) {
        List<String> collectors = ManagementFactory.getGarbageCollectorMXBeans().stream()
                .map(GarbageCollectorMXBean::getName)
                .toList();
        List<String> flags = ManagementFactory.getRuntimeMXBean().getInputArguments().stream()
                .filter(RuntimeInfo::isGcFlag)
                .toList();
        Map<String, Object> gc = new LinkedHashMap<>();
        gc.put("collectors", collectors);
        gc.put("heap_bytes", Runtime.getRuntime().maxMemory());
        if (!flags.isEmpty()) {
            gc.put("flags", flags);
        }
        gc.putAll(extraGc);
        Map<String, Object> runtime = new LinkedHashMap<>();
        runtime.put("gc", gc);
        return runtime;
    }
}
