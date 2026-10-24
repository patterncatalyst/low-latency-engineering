package io.patterncatalyst.lowlat.ch11;

import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/** What one workload measured, and how it becomes a lowlat-report/1 report. */
record Run(long[] samples, Map<String, Long> counters, List<Integer> cpus, long[] ctxSwitches, String notes) {

    static final String EXAMPLE = "11-stackful-stackless";

    static Run of(long[] samples, Map<String, Long> counters, List<Integer> cpus, long[] ctxSwitches, String notes) {
        return new Run(samples, new TreeMap<>(counters), cpus, ctxSwitches, notes);
    }

    /** The two thread kinds every Java workload compares. */
    enum Kind {
        PLATFORM("platform-thread"),
        VIRTUAL("virtual-thread");

        final String variant;

        Kind(String variant) {
            this.variant = variant;
        }

        static Kind parse(String variant) {
            for (Kind k : values()) {
                if (k.variant.equals(variant)) {
                    return k;
                }
            }
            throw new IllegalArgumentException("--variant: platform-thread | virtual-thread");
        }

        Thread.Builder builder() {
            return this == VIRTUAL ? Thread.ofVirtual() : Thread.ofPlatform();
        }
    }

    /** Records the samples, prints the summary and, when {@code report} is given, writes the report. */
    void emit(Kind kind, Path report) {
        LatencyRecorder recorder = LatencyRecorder.singleThreaded(EXAMPLE, kind.variant);
        for (long ns : samples) {
            recorder.record(Math.max(1, ns));
        }
        recorder.printSummary();
        counters.forEach((k, v) -> System.out.println("counter " + k + "=" + v));
        if (report == null) {
            return;
        }
        Map<String, Object> runtime = RuntimeInfo.jvm();
        Map<String, Object> placement = Placement.placement(cpus);
        if (!placement.isEmpty()) {
            runtime.put("placement", placement);
        }
        if (!counters.isEmpty()) {
            runtime.put("counters", RuntimeInfo.counters(new HashMap<>(counters)));
        }
        if (ctxSwitches != null) {
            runtime.put("ctx_switches", Map.of("voluntary", ctxSwitches[0], "involuntary", ctxSwitches[1]));
        }
        recorder.writeReport(report, notes, null, runtime);
        System.out.println("report: " + report);
    }
}
