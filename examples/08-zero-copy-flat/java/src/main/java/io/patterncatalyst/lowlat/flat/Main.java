package io.patterncatalyst.lowlat.flat;

import java.util.List;

/**
 * Entry point of the non-JMH tools of Ch8; the shaded jar's own main class is JMH's, so run these
 * with {@code java --enable-native-access=ALL-UNNAMED -cp benchmarks.jar
 * io.patterncatalyst.lowlat.flat.Main TOOL ...}.
 */
public final class Main {

    static final String USAGE = """
            usage: Main TOOL [options]
              consume      receive the line (protobuf-decode or flat-ffm) and write a latency report
              dump FILE    decode a file of parcel-v1 records and print them as JSON (golden bytes)
              clock-check  compare clock_gettime downcalls with System.nanoTime()
              footprint    object layout and table sizes (JOL); run with and without
                           -XX:+UseCompactObjectHeaders
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
            case "dump" -> Dump.run(rest);
            case "clock-check" -> ClockCheck.run(rest);
            case "footprint" -> Footprint.run(rest);
            default -> {
                System.err.print(USAGE);
                yield 2;
            }
        };
        System.exit(status);
    }
}
