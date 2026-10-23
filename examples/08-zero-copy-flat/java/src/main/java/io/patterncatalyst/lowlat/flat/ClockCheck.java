package io.patterncatalyst.lowlat.flat;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import tools.jackson.databind.json.JsonMapper;

/**
 * Does the downcall read the same clock as {@code System.nanoTime()}? Each sample reads
 * {@code nanoTime()}, then {@code clock_gettime(CLOCK_MONOTONIC)}, then {@code nanoTime()} again. If both
 * are CLOCK_MONOTONIC the downcall value lies between the two {@code nanoTime()} values; the skew of a
 * sample is how far outside that bracket it fell (0 when inside). The tool prints the largest skew per
 * linkage as JSON, and {@code verify.sh} requires it to stay under 1 ms.
 */
final class ClockCheck {

    private static final int SAMPLES = 100_000;

    private ClockCheck() {
    }

    static int run(List<String> args) {
        if (!args.isEmpty()) {
            System.err.println("usage: Main clock-check");
            return 2;
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("samples", SAMPLES);
        try (ClockGettime clock = new ClockGettime()) {
            result.put("standard", skew(clock::standard));
            result.put("critical", skew(clock::critical));
        }
        System.out.println(JsonMapper.builder().build().writerWithDefaultPrettyPrinter().writeValueAsString(result));
        return 0;
    }

    private static Map<String, Object> skew(LongSupplier downcall) {
        long maxSkewNs = 0;
        long maxBracketNs = 0;
        for (int i = 0; i < SAMPLES; i++) {
            long before = System.nanoTime();
            long read = downcall.getAsLong();
            long after = System.nanoTime();
            long outside = Math.max(before - read, Math.max(read - after, 0));
            maxSkewNs = Math.max(maxSkewNs, outside);
            maxBracketNs = Math.max(maxBracketNs, after - before);
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("max_skew_ns", maxSkewNs);
        out.put("max_bracket_ns", maxBracketNs);
        return out;
    }
}
