package io.patterncatalyst.lowlat.line;

import java.net.InetSocketAddress;
import java.nio.file.Path;
import java.util.List;

/** Command-line options of the consumer (see consumers/README.md). */
record Config(
        String bindHost,
        int bindPort,
        int rcvbuf,
        long expect,
        long idleTimeoutMs,
        Path report,
        String example,
        String variant) {

    static final String USAGE = """
            usage: line-consumer-java [--bind HOST:PORT] [--rcvbuf BYTES] [--expect N]
                                      [--idle-timeout-ms MS] [--report FILE]
                                      [--example NAME] [--variant NAME]
              --bind            UDP address to bind (default 127.0.0.1:47000)
              --rcvbuf          SO_RCVBUF request in bytes (default 4194304)
              --expect          stop after N datagrams, received + dropped (default: no limit)
              --idle-timeout-ms stop after MS with nothing received, once the first datagram
                                has arrived (default 2000)
              --report          write the lowlat-report/1 JSON here (needs LOWLAT_PROFILE)
              --example         report example name (default 00-line-consumer)
              --variant         report variant (default baseline)
            """;

    static Config defaults() {
        return new Config("127.0.0.1", 47000, 4 << 20, 0, 2000, null, "00-line-consumer", "baseline");
    }

    InetSocketAddress bindAddress() {
        return new InetSocketAddress(bindHost, bindPort);
    }

    /** Parse the argument vector; throws {@link IllegalArgumentException} with a user-facing message. */
    static Config parse(List<String> args) {
        Config c = defaults();
        for (int i = 0; i < args.size(); i++) {
            String flag = args.get(i);
            if (flag.equals("-h") || flag.equals("--help")) {
                throw new HelpRequested();
            }
            if (i + 1 >= args.size()) {
                throw new IllegalArgumentException("option " + flag + " needs a value");
            }
            String value = args.get(++i);
            c = switch (flag) {
                case "--bind" -> c.withBind(value);
                case "--rcvbuf" -> new Config(c.bindHost, c.bindPort, positiveInt(flag, value), c.expect,
                        c.idleTimeoutMs, c.report, c.example, c.variant);
                case "--expect" -> new Config(c.bindHost, c.bindPort, c.rcvbuf, positiveLong(flag, value),
                        c.idleTimeoutMs, c.report, c.example, c.variant);
                case "--idle-timeout-ms" -> new Config(c.bindHost, c.bindPort, c.rcvbuf, c.expect,
                        positiveLong(flag, value), c.report, c.example, c.variant);
                case "--report" -> new Config(c.bindHost, c.bindPort, c.rcvbuf, c.expect, c.idleTimeoutMs,
                        Path.of(value), c.example, c.variant);
                case "--example" -> new Config(c.bindHost, c.bindPort, c.rcvbuf, c.expect, c.idleTimeoutMs,
                        c.report, value, c.variant);
                case "--variant" -> new Config(c.bindHost, c.bindPort, c.rcvbuf, c.expect, c.idleTimeoutMs,
                        c.report, c.example, value);
                default -> throw new IllegalArgumentException("unknown option " + flag);
            };
        }
        return c;
    }

    private Config withBind(String hostPort) {
        int colon = hostPort.lastIndexOf(':');
        if (colon <= 0) {
            throw new IllegalArgumentException("--bind needs HOST:PORT, got '" + hostPort + "'");
        }
        int port = positiveInt("--bind port", hostPort.substring(colon + 1));
        if (port > 65535) {
            throw new IllegalArgumentException("--bind port out of range: " + port);
        }
        return new Config(hostPort.substring(0, colon), port, rcvbuf, expect, idleTimeoutMs, report,
                example, variant);
    }

    private static int positiveInt(String flag, String value) {
        long v = positiveLong(flag, value);
        if (v > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(flag + " too large: " + value);
        }
        return (int) v;
    }

    private static long positiveLong(String flag, String value) {
        try {
            long v = Long.parseLong(value);
            if (v < 1) {
                throw new IllegalArgumentException(flag + " must be at least 1, got " + value);
            }
            return v;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(flag + " needs a number, got '" + value + "'", e);
        }
    }

    /** Thrown by {@link #parse} for {@code --help}. */
    static final class HelpRequested extends RuntimeException {
        private static final long serialVersionUID = 1L;

        HelpRequested() {
            super("help requested", null, false, false);
        }
    }
}
