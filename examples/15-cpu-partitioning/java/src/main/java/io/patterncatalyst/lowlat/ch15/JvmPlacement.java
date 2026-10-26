package io.patterncatalyst.lowlat.ch15;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.BitSet;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import tools.jackson.databind.SerializationFeature;
import tools.jackson.databind.json.JsonMapper;

/**
 * Which threads of one JVM end up on the isolated CPUs, and what the busy ones cost in preemptions.
 *
 * <p>Two placements of the same program, chosen by how the JVM was started:
 *
 * <ul>
 *   <li>{@code --mode taskset}: the whole JVM runs under {@code taskset -c 2,3}. Every JVM thread (the VM
 *       thread, the GC and compiler workers, the signal dispatcher) inherits the mask, so all of them are
 *       candidates for the isolated CPUs, and with {@code isolcpus=domain} nothing balances the two busy
 *       threads across the pair.
 *   <li>{@code --mode hot-thread}: the JVM runs under {@code taskset -c 0,1} and only the hot thread moves to
 *       {@code --cpu}, with the same OpenHFT Affinity call example 07 uses.
 * </ul>
 *
 * The program samples the last-run CPU of every thread ({@link TaskStat}) every 100 ms while the hot threads
 * spin, and reads each hot thread's own involuntary context switches from {@code /proc/thread-self/status}.
 * Every value is an exact count the kernel reports; none is a time.
 *
 * <pre>
 *   java -cp cpu-partitioning-java.jar io.patterncatalyst.lowlat.ch15.JvmPlacement
 *        --mode taskset|hot-thread --seconds N [--cpu 3] [--isolated 2-3] [--out FILE]
 * </pre>
 */
public final class JvmPlacement {

    private static final long SAMPLE_GAP_MS = 100;

    /** Written by the hot threads so the spin has an effect the JIT cannot drop. */
    private static volatile long sink;

    private JvmPlacement() {}

    /** The command line, validated. */
    record Options(String mode, int seconds, int cpu, BitSet isolated, Path out) {

        static Options parse(String[] args) {
            String mode = null;
            int seconds = 10;
            int cpu = -1;
            String isolated = null;
            Path out = null;
            for (int i = 0; i < args.length; i += 2) {
                if (i + 1 >= args.length) {
                    throw new IllegalArgumentException(args[i] + " needs a value");
                }
                String value = args[i + 1];
                switch (args[i]) {
                    case "--mode" -> mode = value;
                    case "--seconds" -> seconds = Integer.parseInt(value);
                    case "--cpu" -> cpu = Integer.parseInt(value);
                    case "--isolated" -> isolated = value;
                    case "--out" -> out = Path.of(value);
                    default -> throw new IllegalArgumentException("unknown option " + args[i]);
                }
            }
            if (!"taskset".equals(mode) && !"hot-thread".equals(mode)) {
                throw new IllegalArgumentException("--mode taskset | hot-thread");
            }
            if (seconds < 1) {
                throw new IllegalArgumentException("--seconds must be at least 1");
            }
            if ("hot-thread".equals(mode) && cpu < 0) {
                throw new IllegalArgumentException("--mode hot-thread needs --cpu");
            }
            return new Options(mode, seconds, cpu, CpuLists.parse(isolated != null ? isolated : readIsolated()), out);
        }
    }

    /** What one hot thread saw of itself. */
    record HotResult(String name, long tid, String allowed, long voluntary, long involuntary) {}

    /** The kernel's isolated CPU list, empty without {@code isolcpus}. */
    static String readIsolated() {
        try {
            return Files.readString(Path.of("/sys/devices/system/cpu/isolated")).strip();
        } catch (IOException e) {
            return "";
        }
    }

    /** {@code nonvoluntary_ctxt_switches} (or {@code voluntary_ctxt_switches}) from a /proc status text; -1 when absent. */
    static long statusCounter(String status, String key) {
        for (String line : status.split("\n")) {
            if (line.startsWith(key + ":")) {
                return Long.parseLong(line.substring(key.length() + 1).strip());
            }
        }
        return -1;
    }

    /** The calling thread's own status file ({@code /proc/thread-self} is the task directory of this thread). */
    private static String threadStatus() throws IOException {
        return Files.readString(Path.of("/proc/thread-self/status"));
    }

    private static HotResult spin(String name, int pinTo, long nanos) throws IOException {
        if (pinTo >= 0) {
            HotThread.pinTo(pinTo);
        }
        String before = threadStatus();
        long tid = Long.parseLong(Path.of("/proc/thread-self").toRealPath().getFileName().toString());
        long x = 0;
        for (long end = System.nanoTime() + nanos; System.nanoTime() < end; ) {
            x++;
            Thread.onSpinWait();
        }
        sink = x;
        String after = threadStatus();
        return new HotResult(
                name,
                tid,
                CpuLists.format(HotThread.allowed()),
                statusCounter(after, "voluntary_ctxt_switches") - statusCounter(before, "voluntary_ctxt_switches"),
                statusCounter(after, "nonvoluntary_ctxt_switches") - statusCounter(before, "nonvoluntary_ctxt_switches"));
    }

    /** Runs the placement and returns the report. */
    static Map<String, Object> run(Options o) throws Exception {
        boolean pinned = "hot-thread".equals(o.mode());
        String[] names = pinned ? new String[] {"decide-hot"} : new String[] {"decide-a", "decide-b"};
        List<HotResult> hot = new ArrayList<>();
        List<Thread> threads = new ArrayList<>();
        List<Throwable> failures = new ArrayList<>();
        for (String name : names) {
            threads.add(Thread.ofPlatform().name(name).start(() -> {
                try {
                    HotResult r = spin(name, pinned ? o.cpu() : -1, o.seconds() * 1_000_000_000L);
                    synchronized (hot) {
                        hot.add(r);
                    }
                } catch (Throwable t) {
                    synchronized (failures) {
                        failures.add(t);
                    }
                }
            }));
        }
        // Sample the last-run CPU of every thread of this JVM until the hot threads end.
        Map<String, Map<Integer, Integer>> seen = new TreeMap<>();
        int samples = 0;
        for (Thread t : threads) {
            while (t.isAlive()) {
                for (Map.Entry<String, Integer> e : TaskStat.sampleSelf().entrySet()) {
                    seen.computeIfAbsent(e.getKey(), k -> new TreeMap<>()).merge(e.getValue(), 1, Integer::sum);
                }
                samples++;
                t.join(SAMPLE_GAP_MS);
            }
        }
        if (!failures.isEmpty()) {
            throw new IllegalStateException("a hot thread failed", failures.get(0));
        }
        List<Map<String, Object>> threadRows = new ArrayList<>();
        int onIsolated = 0;
        for (Map.Entry<String, Map<Integer, Integer>> e : seen.entrySet()) {
            boolean touched = e.getValue().keySet().stream().anyMatch(o.isolated()::get);
            onIsolated += touched ? 1 : 0;
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("thread", e.getKey());
            row.put("cpus", e.getValue());
            row.put("on_isolated", touched);
            threadRows.add(row);
        }
        hot.sort(Comparator.comparing(HotResult::name));
        List<Map<String, Object>> hotRows = new ArrayList<>();
        BitSet hotCpus = new BitSet();
        for (HotResult r : hot) {
            Map<Integer, Integer> cpus = seen.getOrDefault(r.name() + "-" + r.tid(), Map.of());
            cpus.keySet().forEach(hotCpus::set);
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("name", r.name());
            row.put("tid", r.tid());
            row.put("allowed", r.allowed());
            row.put("cpus_seen", cpus);
            row.put("voluntary_switches", r.voluntary());
            row.put("involuntary_switches", r.involuntary());
            hotRows.add(row);
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("schema", "lowlat-placement-java/1");
        out.put("example", "15-cpu-partitioning");
        out.put("language", "java");
        out.put("mode", o.mode());
        out.put("seconds", o.seconds());
        out.put("isolated", CpuLists.format(o.isolated()));
        out.put("process_cpus_allowed", processCpusAllowed());
        out.put("available_processors", Runtime.getRuntime().availableProcessors());
        out.put("samples", samples);
        out.put("threads_total", seen.size());
        out.put("threads_on_isolated", onIsolated);
        out.put("hot_distinct_cpus", hotCpus.cardinality());
        out.put("hot_threads", hotRows);
        out.put("threads", threadRows);
        return out;
    }

    /** The process-wide mask the JVM started with ({@code Cpus_allowed_list} of /proc/self/status). */
    static String processCpusAllowed() throws IOException {
        for (String line : Files.readAllLines(Path.of("/proc/self/status"))) {
            if (line.startsWith("Cpus_allowed_list:")) {
                return line.substring("Cpus_allowed_list:".length()).strip();
            }
        }
        return "";
    }

    public static void main(String[] args) throws Exception {
        Options options;
        try {
            options = Options.parse(args);
        } catch (IllegalArgumentException e) {
            System.err.println("JvmPlacement: " + e.getMessage());
            System.err.println("usage: JvmPlacement --mode taskset|hot-thread --seconds N [--cpu N] [--isolated LIST] [--out FILE]");
            System.exit(2);
            return;
        }
        String json = JsonMapper.builder().enable(SerializationFeature.INDENT_OUTPUT).build().writeValueAsString(run(options))
                + System.lineSeparator();
        if (options.out() != null) {
            Files.writeString(options.out(), json);
        } else {
            System.out.print(json);
        }
    }
}
