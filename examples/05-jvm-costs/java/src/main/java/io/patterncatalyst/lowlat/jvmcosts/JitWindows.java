package io.patterncatalyst.lowlat.jvmcosts;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordingFile;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.SerializationFeature;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * Counts the JIT's work per window from a JFR recording, and adds it to reports as {@code runtime.jit}.
 *
 * <p>A compilation is one {@code jdk.Compilation} event that succeeded; {@code c2_compilations} are the
 * ones at tier 4. A deoptimization is one {@code jdk.Deoptimization} event: compiled code that had to
 * fall back to the interpreter because an assumption broke. Each event belongs to the window its start
 * time falls in:
 *
 * <ul>
 *   <li>{@code startup}: before the first parcel (class loading, a warm-up replay, the bind);
 *   <li>{@code first-N}: from the first parcel to the first parcel past the window;
 *   <li>{@code steady}: from there to the end of the run.
 * </ul>
 *
 * <p>Usage: {@code JitWindows --jfr FILE --first T --boundary T --end T --window N REPORT.json...},
 * with the three instants printed by {@link Costs} (ISO-8601). Events are the observation here, not an
 * assertion: they say where the compiler worked.
 */
public final class JitWindows {

    static final String COMPILATION = "jdk.Compilation";
    static final String DEOPTIMIZATION = "jdk.Deoptimization";
    private static final int C2_LEVEL = 4;
    private static final String SUCCEEDED = "succeded"; // the JDK's own spelling of the jdk.Compilation field

    private JitWindows() {
    }

    /** The three window boundaries of one run. */
    record Windows(Instant first, Instant boundary, Instant end, long window) {

        String firstKey() {
            return "first-" + window;
        }

        /** The window an event starting at {@code t} falls in, or null after the run ended. */
        String keyOf(Instant t) {
            if (t.isBefore(first)) {
                return "startup";
            }
            if (t.isBefore(boundary)) {
                return firstKey();
            }
            return t.isAfter(end) ? null : "steady";
        }
    }

    /** Per-window counts, keyed {@code startup}, {@code first-N}, {@code steady}, in that order. */
    static Map<String, Map<String, Long>> count(Path jfr, Windows windows) {
        Map<String, Map<String, Long>> counts = new LinkedHashMap<>();
        for (String key : List.of("startup", windows.firstKey(), "steady")) {
            Map<String, Long> window = new LinkedHashMap<>();
            window.put("compilations", 0L);
            window.put("c2_compilations", 0L);
            window.put("deoptimizations", 0L);
            counts.put(key, window);
        }
        try (RecordingFile file = new RecordingFile(jfr)) {
            while (file.hasMoreEvents()) {
                RecordedEvent event = file.readEvent();
                String name = event.getEventType().getName();
                if (!name.equals(COMPILATION) && !name.equals(DEOPTIMIZATION)) {
                    continue;
                }
                String key = windows.keyOf(event.getStartTime());
                if (key == null) {
                    continue;
                }
                Map<String, Long> window = counts.get(key);
                if (name.equals(DEOPTIMIZATION)) {
                    window.merge("deoptimizations", 1L, Long::sum);
                } else if (event.getBoolean(SUCCEEDED)) {
                    window.merge("compilations", 1L, Long::sum);
                    if (event.getInt("compileLevel") == C2_LEVEL) {
                        window.merge("c2_compilations", 1L, Long::sum);
                    }
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException("cannot read recording " + jfr, e);
        }
        return counts;
    }

    /** Sets {@code runtime.jit} in the report at {@code report}; the rest of the report is unchanged. */
    static void addTo(Path report, Map<String, Map<String, Long>> counts) {
        ObjectMapper mapper = JsonMapper.builder().enable(SerializationFeature.INDENT_OUTPUT).build();
        JsonNode root = mapper.readTree(report);
        if (!(root instanceof ObjectNode document)) {
            throw new IllegalArgumentException(report + " is not a JSON object");
        }
        ObjectNode runtime = document.get("runtime") instanceof ObjectNode existing
                ? existing : document.putObject("runtime");
        runtime.set("jit", mapper.valueToTree(counts));
        mapper.writeValue(report, document);
    }

    public static void main(String[] args) {
        Map<String, String> option = new LinkedHashMap<>();
        List<Path> reports = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            if (args[i].startsWith("--") && i + 1 < args.length) {
                option.put(args[i].substring(2), args[++i]);
            } else {
                reports.add(Path.of(args[i]));
            }
        }
        for (String required : List.of("jfr", "first", "boundary", "end", "window")) {
            if (!option.containsKey(required)) {
                System.err.println("missing --" + required);
                System.err.println("usage: JitWindows --jfr FILE --first T --boundary T --end T --window N REPORT.json...");
                System.exit(2);
            }
        }
        Instant end = Instant.parse(option.get("end"));
        // "null" is what Costs prints for a parcel it never saw: no first parcel means no first window.
        Instant first = option.get("first").equals("null") ? end : Instant.parse(option.get("first"));
        Instant boundary = option.get("boundary").equals("null") ? end : Instant.parse(option.get("boundary"));
        Windows windows = new Windows(first, boundary, end, Long.parseLong(option.get("window")));
        Map<String, Map<String, Long>> counts = count(Path.of(option.get("jfr")), windows);
        reports.forEach(report -> addTo(report, counts));
        counts.forEach((key, window) -> System.out.printf("jit %-11s compilations %d (c2 %d), deoptimizations %d%n", key,
                window.get("compilations"), window.get("c2_compilations"), window.get("deoptimizations")));
    }
}
