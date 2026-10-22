package io.patterncatalyst.lowlat.measure;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordingFile;

/**
 * Turns the GC pauses in a JFR recording into a {@code gc-pause} latency report.
 *
 * <p>Every {@code jdk.GCPhasePause} event is one sample (its duration in ns): for ZGC and
 * Shenandoah that is each stop-the-world phase, for G1 and Parallel the top-level pause. The
 * nested {@code jdk.GCPhasePauseLevel1..4} sub-phases are not counted, so a pause is never
 * counted twice. {@code jdk.ZAllocationStall} events are counted separately into
 * {@code runtime.alloc_stalls}, and {@code jdk.GCConfiguration} names the collectors in
 * {@code runtime.gc}.
 *
 * <p>Usage: {@code java -cp measure-java-cli.jar io.patterncatalyst.lowlat.measure.JfrPauses
 * --jfr FILE --example NAME --variant NAME --out REPORT.json [--notes TEXT]}. The variant gets
 * the suffix {@code -gc-pause}. Needs {@code LOWLAT_PROFILE}, like every report.
 */
public final class JfrPauses {

    public static final String VARIANT_SUFFIX = "-gc-pause";
    static final String PAUSE = "jdk.GCPhasePause";
    static final String STALL = "jdk.ZAllocationStall";
    static final String CONFIG = "jdk.GCConfiguration";

    private JfrPauses() {}

    public static void main(String[] args) {
        Map<String, String> opt = new LinkedHashMap<>();
        for (int i = 0; i < args.length; i += 2) {
            if (!args[i].startsWith("--") || i + 1 >= args.length) {
                usage("bad argument: " + args[i]);
            }
            opt.put(args[i].substring(2), args[i + 1]);
        }
        for (String required : List.of("jfr", "example", "variant", "out")) {
            if (!opt.containsKey(required)) {
                usage("missing --" + required);
            }
        }
        Report r = write(Path.of(opt.get("jfr")), opt.get("example"), opt.get("variant"),
                Path.of(opt.get("out")), opt.get("notes"));
        System.out.printf("%s: %d GC pauses, p99 %d ns, max %d ns%n", r.variant(), r.count(),
                r.percentiles().p99(), r.percentiles().max());
    }

    private static void usage(String problem) {
        System.err.println(problem);
        System.err.println("usage: JfrPauses --jfr FILE --example NAME --variant NAME --out REPORT.json [--notes TEXT]");
        System.exit(2);
    }

    /** Read {@code jfr} and write the report; the variant is {@code variant + "-gc-pause"}. */
    public static Report write(Path jfr, String example, String variant, Path out, String notes) {
        LatencyRecorder rec = LatencyRecorder.singleThreaded(example, variant + VARIANT_SUFFIX);
        long stalls = 0;
        long maxStallNs = 0;
        String young = null;
        String old = null;
        try (RecordingFile file = new RecordingFile(jfr)) {
            while (file.hasMoreEvents()) {
                RecordedEvent e = file.readEvent();
                switch (e.getEventType().getName()) {
                    case PAUSE -> rec.record(e.getDuration().toNanos());
                    case STALL -> {
                        stalls++;
                        maxStallNs = Math.max(maxStallNs, e.getDuration().toNanos());
                    }
                    case CONFIG -> {
                        young = e.getString("youngCollector");
                        old = e.getString("oldCollector");
                    }
                    default -> { }
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException("cannot read recording " + jfr, e);
        }
        Map<String, Object> runtime = new LinkedHashMap<>();
        Map<String, Object> gc = new LinkedHashMap<>();
        List<String> names = new ArrayList<>();
        for (String n : new String[] {young, old}) {
            if (n != null && !n.isBlank() && !names.contains(n)) {
                names.add(n);
            }
        }
        if (!names.isEmpty()) {
            gc.put("name", String.join(" + ", names));
            gc.put("collectors", names);
            runtime.put("gc", gc);
        }
        Map<String, Object> allocStalls = new LinkedHashMap<>();
        allocStalls.put("count", stalls);
        allocStalls.put("max_ns", maxStallNs);
        runtime.put("alloc_stalls", allocStalls);
        String note = "GC pauses from " + jfr.getFileName() + " (" + PAUSE + " durations, ns)"
                + (notes == null || notes.isBlank() ? "" : "; " + notes);
        return rec.writeReport(out, note, null, runtime);
    }
}
