package io.patterncatalyst.lowlat.lockfree;

import java.util.List;

/**
 * Ch10 entry point.
 *
 * <pre>
 *   claim   --variant mutex|cas-loop|fetch-add [--stalled-producer]
 *   seqlock --variant rw-lock|stamped-lock
 *   line    --variant blocking-queue|agrona-mpsc
 * </pre>
 *
 * Shared options: {@code --cpus A,B,...} pins the threads (distinct physical cores), {@code --hold-ms}
 * keeps them waiting after {@code placement-ready} so a script can check the pins, {@code --report FILE}
 * writes the lowlat-report/1 JSON (needs {@code LOWLAT_PROFILE}). The litmus tests are jcstress tests
 * ({@code StoreBufferVolatile}, {@code StoreBufferAcquireRelease}), run through the jcstress jar.
 */
public final class Main {

    private Main() {
    }

    public static void main(String[] argv) throws Exception {
        if (argv.length < 1) {
            usage();
            return;
        }
        try {
            Args args = new Args(List.of(argv).subList(1, argv.length));
            String variant = args.text("variant", "");
            switch (argv[0]) {
                case "claim" -> ClaimRun.execute(variant, args);
                case "seqlock" -> SeqlockRun.execute(variant, args);
                case "line" -> LineRun.execute(variant, args);
                default -> {
                    usage();
                    System.exit(2);
                }
            }
        } catch (IllegalArgumentException e) {
            System.err.println("lockfree-java: " + e.getMessage());
            System.exit(2);
        }
    }

    private static void usage() {
        System.err.println("usage: Main claim|seqlock|line --variant NAME [--cpus A,B,..] [--hold-ms N] [--report FILE] [options]");
    }
}
