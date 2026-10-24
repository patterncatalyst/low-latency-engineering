package io.patterncatalyst.lowlat.eliminating;

import java.util.List;

/**
 * Entry point of the non-JMH tools of Ch9; the shaded jar's own main class is JMH's, so run these with
 * {@code java --enable-native-access=ALL-UNNAMED -cp benchmarks.jar io.patterncatalyst.lowlat.eliminating.Main TOOL ...}.
 */
public final class Main {

    static final String USAGE = """
            usage: Main TOOL [options]
              consume    receive the line against the hub tracker (node-map or flat-map) and write a latency report
              counters   five camera threads' counters: adjacent-counters, pair-padded, line-padded or smt-siblings
              footprint  object layout and tracker sizes (JOL)
            """;

    private Main() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.print(USAGE);
            System.exit(2);
        }
        List<String> rest = List.of(args).subList(1, args.length);
        int status = switch (args[0]) {
            case "consume" -> LineRun.run(rest);
            case "counters" -> CountersRun.run(rest);
            case "footprint" -> Footprint.run(rest);
            default -> {
                System.err.print(USAGE);
                yield 2;
            }
        };
        System.exit(status);
    }
}
