package io.patterncatalyst.lowlat.co;

import io.patterncatalyst.lowlat.line.Config;
import java.net.InetSocketAddress;
import java.nio.file.Path;
import java.util.List;

/** Command line of {@code co-experiment-java run|probe}. */
record Options(String bindHost, int bindPort, int rcvbuf, long expect, int idleTimeoutMs,
               long stallMs, long stallSeq, String suffix, Path outDir) {

    static Options parse(List<String> args) {
        String bind = "127.0.0.1:47231";
        int rcvbuf = 4 << 20;
        long expect = 10_000;
        long stallMs = 200;
        long stallSeq = 5_000;
        String suffix = "";
        Path out = Path.of(".");
        for (int i = 0; i < args.size(); i++) {
            String opt = args.get(i);
            if (!opt.startsWith("--")) {
                throw new IllegalArgumentException("unexpected argument '" + opt + "'");
            }
            if (i + 1 >= args.size()) {
                throw new IllegalArgumentException(opt + " needs a value");
            }
            String val = args.get(++i);
            switch (opt) {
                case "--bind" -> bind = val;
                case "--expect" -> expect = Long.parseLong(val);
                case "--stall-ms" -> stallMs = Long.parseLong(val);
                case "--stall-seq" -> stallSeq = Long.parseLong(val);
                case "--suffix" -> suffix = val;
                case "--out" -> out = Path.of(val);
                default -> throw new IllegalArgumentException("unknown option '" + opt + "'");
            }
        }
        Config.HostPort hostPort = Config.HostPort.parse("--bind", bind);
        if (expect <= 0 || stallMs < 0) {
            throw new IllegalArgumentException("--expect must be > 0 and --stall-ms >= 0");
        }
        return new Options(hostPort.host(), hostPort.port(), rcvbuf,
                expect, 2000, stallMs, stallSeq, suffix, out);
    }

    InetSocketAddress bindAddress() {
        return new InetSocketAddress(bindHost, bindPort);
    }
}
