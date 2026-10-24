package io.patterncatalyst.lowlat.ch12;

import java.util.List;

/**
 * Ch12 plain-JDK entry point.
 *
 * <pre>
 *   receive --variant selector|virtual-thread-blocking|thread-per-core   the UDP receive micro lane
 *   client  --url URL --rate HZ --seconds S ...                          the open-loop HTTP client (D6)
 * </pre>
 *
 * Shared options: {@code --cpus A,B,...} pins the threads (distinct physical cores), {@code --hold-ms}
 * keeps them waiting after {@code placement-ready} so a script can check the pins, {@code --report FILE}
 * writes the lowlat-report/1 JSON (needs {@code LOWLAT_PROFILE}).
 */
public final class Main {

    private Main() {
    }

    public static void main(String[] argv) throws Exception {
        if (argv.length < 1) {
            usage();
            System.exit(2);
        }
        try {
            Args args = new Args(List.of(argv).subList(1, argv.length));
            switch (argv[0]) {
                case "receive" -> ReceiveRun.execute(args.text("variant", ""), args);
                case "client" -> OpenLoopClient.execute(args);
                default -> {
                    usage();
                    System.exit(2);
                }
            }
        } catch (IllegalArgumentException e) {
            System.err.println("io-engines-java: " + e.getMessage());
            System.exit(2);
        }
    }

    private static void usage() {
        System.err.println("usage: Main receive|client [--key value ...]");
    }
}
