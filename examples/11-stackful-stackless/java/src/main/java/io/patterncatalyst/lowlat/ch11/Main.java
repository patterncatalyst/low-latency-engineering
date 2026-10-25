package io.patterncatalyst.lowlat.ch11;

import java.util.List;

/**
 * Ch11 entry point.
 *
 * <pre>
 *   parked   --variant platform-thread|virtual-thread [--tasks 10000] [--wait-ms 1000]
 *   pingpong --variant platform-thread|virtual-thread [--rounds 1000000] [--batch 1000]
 *   pinning  [--tasks 100] [--block-ms 5]
 *   line     --variant platform-thread|virtual-thread [--base-port 47313] [--expect 200000]
 * </pre>
 *
 * Shared options: {@code --cpus A,B} pins the measured threads, {@code --hold-ms} keeps them waiting after
 * {@code placement-ready} so a script can check the pins, {@code --report FILE} writes the lowlat-report/1 JSON
 * (needs {@code LOWLAT_PROFILE}). Every measured loop runs once unreported first, so the JIT, the class loading
 * and the virtual-thread carriers are warm when the reported pass starts.
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
            Placement.captureBaseAffinity();
            switch (argv[0]) {
                case "parked" -> parked(args);
                case "pingpong" -> pingpong(args);
                case "pinning" -> pinning(args);
                case "line" -> {
                    Run.Kind kind = Run.Kind.parse(args.text("variant", ""));
                    int cpu = args.cpus(1).get(0);
                    LineRun.execute(kind, (int) args.number("base-port", 47313), args.number("expect", 200_000), cpu,
                            args.number("hold-ms", 0), args.number("warmup-parcels", 5_000), args.report());
                }
                default -> {
                    usage();
                    System.exit(2);
                }
            }
        } catch (IllegalArgumentException | IllegalStateException e) {
            System.err.println("stackful-stackless-java: " + e.getMessage() + (e.getCause() == null ? "" : " (" + e.getCause() + ")"));
            System.exit(2);
        }
    }

    private static void parked(Args args) throws InterruptedException {
        Run.Kind kind = Run.Kind.parse(args.text("variant", ""));
        int tasks = (int) args.number("tasks", 10_000);
        long waitMs = args.number("wait-ms", 1000);
        ParkedRun.execute(kind, Math.min(tasks, 2_000), 100, false, 0); // warm: the same loop at a smaller size
        ParkedRun.execute(kind, tasks, waitMs, true, args.number("hold-ms", 0)).emit(kind, args.report());
    }

    private static void pingpong(Args args) throws InterruptedException {
        Run.Kind kind = Run.Kind.parse(args.text("variant", ""));
        long rounds = args.number("rounds", 1_000_000);
        int batch = (int) args.number("batch", 1000);
        List<Integer> cpus = args.cpus(kind == Run.Kind.PLATFORM ? 2 : 1);
        PingPongRun.execute(kind, Math.max(batch, rounds / 5 / batch * batch), batch, 5, cpus, 0, false); // warm: the same loop, fewer rounds
        PingPongRun.execute(kind, rounds, batch, 20, cpus, args.number("hold-ms", 0), true).emit(kind, args.report());
    }

    private static void pinning(Args args) throws Exception {
        int tasks = (int) args.number("tasks", 100);
        long blockMs = args.number("block-ms", 5);
        PinningRun.execute(Math.min(tasks, 20), blockMs); // warm: loads the FFM linker, the JFR classes and the carriers
        PinningRun.execute(tasks, blockMs).emit(Run.Kind.VIRTUAL, args.report());
    }

    private static void usage() {
        System.err.println("usage: Main parked|pingpong|pinning|line --variant platform-thread|virtual-thread [--cpus A,B] [--hold-ms N] [--report FILE]");
    }
}
