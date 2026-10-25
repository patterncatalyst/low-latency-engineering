package io.patterncatalyst.lowlat.measure;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

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

    /** Where {@code runtime.hw_counters} came from; {@link #json()} is the schema's enum value. */
    public enum HwSource {
        PERF("perf"),
        CACHEGRIND("cachegrind"),
        PERFNORM("perfnorm");

        private final String json;

        HwSource(String json) {
            this.json = json;
        }

        public String json() {
            return json;
        }
    }

    /**
     * {@code runtime.placement}: the logical CPUs the measured threads were pinned to, whether they
     * sit on distinct physical cores, and whether any two are SMT siblings. Put the result under
     * {@code "placement"} in the runtime map.
     */
    public static Map<String, Object> placement(List<Integer> cpus, boolean distinctCores, boolean smtSiblings) {
        Map<String, Object> placement = new LinkedHashMap<>();
        placement.put("cpus", List.copyOf(cpus));
        placement.put("distinct_cores", distinctCores);
        placement.put("smt_siblings", smtSiblings);
        return placement;
    }

    /**
     * {@code runtime.hw_counters}: event name to count per operation, for a region of {@code ops}
     * operations. Put the result under {@code "hw_counters"} in the runtime map.
     *
     * @throws IllegalArgumentException when {@code ops} is not positive
     */
    public static Map<String, Object> hwCounters(HwSource source, long ops, Map<String, Double> perOp) {
        if (ops < 1) {
            throw new IllegalArgumentException("ops must be positive: " + ops);
        }
        Map<String, Object> hw = new LinkedHashMap<>();
        hw.put("source", source.json());
        hw.put("ops", ops);
        hw.put("per_op", new TreeMap<>(perOp));
        return hw;
    }

    /** Where the measured program ran; {@link #json()} is the schema's enum value. */
    public enum EnvKind {
        HOST("host"),
        VM("vm"),
        CONTAINER("container");

        private final String json;

        EnvKind(String json) {
            this.json = json;
        }

        public String json() {
            return json;
        }
    }

    /** Container network mode; {@link #json()} is the schema's enum value. */
    public enum NetworkMode {
        HOST("host"),
        BRIDGE("bridge"),
        NONE("none");

        private final String json;

        NetworkMode(String json) {
            this.json = json;
        }

        public String json() {
            return json;
        }
    }

    /**
     * {@code runtime.environment.container}. {@code cpuQuota} (CPUs, like "2") and {@code cpuset}
     * (like "2,3") are null when the limit is not set; {@code seccomp} is "default" or a profile
     * file name, never "unconfined".
     */
    public record ContainerInfo(String runtime, String image, String imageDigest, NetworkMode network,
            String cpuQuota, String cpuset, String seccomp) {

        Map<String, Object> toJson() {
            Map<String, Object> c = new LinkedHashMap<>();
            c.put("runtime", runtime);
            c.put("image", image);
            c.put("image_digest", imageDigest);
            c.put("network", network.json());
            c.put("cpu_quota", cpuQuota);
            c.put("cpuset", cpuset);
            c.put("seccomp", seccomp);
            return c;
        }
    }

    /** {@code runtime.environment.cgroup}: cgroup v2 facts read after the run; a null field is written as null. */
    public record CgroupInfo(String cpuMax, String cpusetEffective, Long nrThrottled, Long throttledUsec) {

        Map<String, Object> toJson() {
            Map<String, Object> g = new LinkedHashMap<>();
            g.put("cpu_max", cpuMax);
            g.put("cpuset_effective", cpusetEffective);
            g.put("nr_throttled", nrThrottled);
            g.put("throttled_usec", throttledUsec);
            return g;
        }
    }

    /**
     * {@code runtime.environment}. The schema requires {@code guestProfile} (snapshot/profile, for
     * example "lab-ready-r04/stock-unpinned") for vm and container and {@code container} for
     * container, and forbids both on host (and {@code container} on vm); {@code lowlat-report
     * check} enforces that, so this builder does not. Null {@code guestProfile}, {@code container}
     * and {@code cgroup} are left out. Put the result under {@code "environment"} in the runtime map.
     */
    public static Map<String, Object> environment(EnvKind kind, String guestProfile, ContainerInfo container,
            CgroupInfo cgroup) {
        Map<String, Object> env = new LinkedHashMap<>();
        env.put("kind", kind.json());
        if (guestProfile != null) {
            env.put("guest_profile", guestProfile);
        }
        if (container != null) {
            env.put("container", container.toJson());
        }
        if (cgroup != null) {
            env.put("cgroup", cgroup.toJson());
        }
        return env;
    }

    /**
     * {@code runtime.counters}: exact event counts (CAS failures, max retries, torn reads, ...), sorted by name so the report is stable. Put
     * the result under {@code "counters"} in the runtime map.
     */
    public static Map<String, Object> counters(Map<String, Long> counts) {
        return new TreeMap<>(counts);
    }

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
