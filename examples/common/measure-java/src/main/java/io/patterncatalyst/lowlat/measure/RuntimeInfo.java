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

    private static final List<String> GC_FLAG_PREFIXES =
            List.of("-XX:+Use", "-XX:-Use", "-Xmx", "-Xms", "-XX:MaxGCPauseMillis", "-XX:+ZGenerational",
                    "-XX:-ZGenerational", "-Xlog:gc", "-XX:+AlwaysPreTouch");

    private RuntimeInfo() {}

    /**
     * {@code gc.collectors}: the {@code GarbageCollectorMXBean} names; {@code gc.flags}: the GC-
     * and heap-related JVM input arguments. The map is mutable so the caller can add more keys.
     */
    public static Map<String, Object> jvm() {
        List<String> collectors = ManagementFactory.getGarbageCollectorMXBeans().stream()
                .map(GarbageCollectorMXBean::getName)
                .toList();
        List<String> flags = ManagementFactory.getRuntimeMXBean().getInputArguments().stream()
                .filter(a -> GC_FLAG_PREFIXES.stream().anyMatch(a::startsWith))
                .toList();
        Map<String, Object> gc = new LinkedHashMap<>();
        gc.put("collectors", collectors);
        gc.put("heap_bytes", Runtime.getRuntime().maxMemory());
        if (!flags.isEmpty()) {
            gc.put("flags", flags);
        }
        Map<String, Object> runtime = new LinkedHashMap<>();
        runtime.put("gc", gc);
        return runtime;
    }
}
