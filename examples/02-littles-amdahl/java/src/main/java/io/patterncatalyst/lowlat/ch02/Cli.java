package io.patterncatalyst.lowlat.ch02;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/** The {@code --key value} command line shared by the chapter's two programs. */
final class Cli {

    private Cli() {
    }

    /**
     * Pairs up {@code --key value} arguments.
     *
     * @throws IllegalArgumentException for a key without a value or a key not in {@code allowed}
     */
    static Map<String, String> pairs(String[] args, Set<String> allowed) {
        Map<String, String> kv = new HashMap<>();
        for (int i = 0; i < args.length; i += 2) {
            if (i + 1 >= args.length) {
                throw new IllegalArgumentException(args[i] + " needs a value");
            }
            kv.put(args[i], args[i + 1]);
        }
        for (String key : kv.keySet()) {
            if (!allowed.contains(key)) {
                throw new IllegalArgumentException("unknown option " + key);
            }
        }
        return kv;
    }
}
