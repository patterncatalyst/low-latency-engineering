package io.patterncatalyst.lowlat.lockfree;

import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** {@code --key value} pairs and {@code --flag} switches after the sub-command. */
final class Args {

    private static final List<String> SWITCHES = List.of("stalled-producer");

    private final Map<String, String> values = new HashMap<>();

    Args(List<String> args) {
        for (int i = 0; i < args.size(); i++) {
            String key = args.get(i);
            if (!key.startsWith("--")) {
                throw new IllegalArgumentException("unexpected argument '" + key + "'");
            }
            key = key.substring(2);
            if (SWITCHES.contains(key)) {
                values.put(key, "1");
            } else if (i + 1 < args.size()) {
                values.put(key, args.get(++i));
            } else {
                throw new IllegalArgumentException("--" + key + " needs a value");
            }
        }
    }

    boolean flag(String key) {
        return values.containsKey(key);
    }

    String text(String key, String fallback) {
        return values.getOrDefault(key, fallback);
    }

    long number(String key, long fallback) {
        String value = values.get(key);
        try {
            return value == null ? fallback : Long.parseLong(value);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("--" + key + " needs a number, got '" + value + "'", e);
        }
    }

    /** The CPUs of {@code --cpus}, exactly {@code needed} of them; -1 each when the option is absent (unpinned). */
    List<Integer> cpus(int needed) {
        String list = values.get("cpus");
        if (list == null || list.isBlank()) {
            return java.util.Collections.nCopies(needed, -1);
        }
        List<Integer> cpus = Placement.parseCpus(list);
        if (cpus.size() < needed) {
            throw new IllegalArgumentException("--cpus needs " + needed + " CPUs, got " + cpus.size());
        }
        return cpus.subList(0, needed);
    }

    Path report() {
        String path = values.get("report");
        return path == null ? null : Path.of(path);
    }
}
