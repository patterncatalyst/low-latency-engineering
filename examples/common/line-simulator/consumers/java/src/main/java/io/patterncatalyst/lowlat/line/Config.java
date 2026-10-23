package io.patterncatalyst.lowlat.line;

import java.net.InetSocketAddress;
import java.nio.file.Path;
import java.util.List;

/** Command-line options of the consumer (see consumers/README.md). */
public record Config(
        String bindHost,
        int bindPort,
        int rcvbuf,
        long expect,
        long idleTimeoutMs,
        Path report,
        String example,
        String variant,
        long window) {

    static final String USAGE = """
            usage: line-consumer-java [--bind HOST:PORT] [--rcvbuf BYTES] [--expect N]
                                      [--idle-timeout-ms MS] [--report FILE]
                                      [--example NAME] [--variant NAME] [--window N]
              --bind            UDP address to bind (default 127.0.0.1:47000)
              --rcvbuf          SO_RCVBUF request in bytes (default 4194304)
              --expect          stop after N datagrams, received + dropped (default: no limit)
              --idle-timeout-ms stop after MS with nothing received, once the first datagram
                                has arrived (default 2000)
              --report          write the lowlat-report/1 JSON here (needs LOWLAT_PROFILE)
              --example         report example name (default 00-line-consumer)
              --variant         report variant (default baseline)
              --window          also report parcels seq < N as <variant>-first-N and the rest
                                as <variant>-steady, beside --report (default: none)
            """;

    /** A config without a window. */
    public Config(String bindHost, int bindPort, int rcvbuf, long expect, long idleTimeoutMs, Path report,
            String example, String variant) {
        this(bindHost, bindPort, rcvbuf, expect, idleTimeoutMs, report, example, variant, 0);
    }

    public static Config defaults() {
        return new Config("127.0.0.1", 47000, 4 << 20, 0, 2000, null, "00-line-consumer", "baseline", 0);
    }

    public InetSocketAddress bindAddress() {
        return new InetSocketAddress(bindHost, bindPort);
    }

    /** Parse the argument vector; throws {@link IllegalArgumentException} with a user-facing message. */
    public static Config parse(List<String> args) {
        return parse(args, defaults());
    }

    /**
     * Parse over {@code base}: an example starts from its own defaults (port, example name,
     * variant) and still gets the common flags and their validation.
     */
    public static Config parse(List<String> args, Config base) {
        String bindHost = base.bindHost;
        int bindPort = base.bindPort;
        int rcvbuf = base.rcvbuf;
        long expect = base.expect;
        long idleTimeoutMs = base.idleTimeoutMs;
        Path report = base.report;
        String example = base.example;
        String variant = base.variant;
        long window = base.window;
        for (int i = 0; i < args.size(); i++) {
            String flag = args.get(i);
            if (flag.equals("-h") || flag.equals("--help")) {
                throw new HelpRequested();
            }
            if (i + 1 >= args.size()) {
                throw new IllegalArgumentException("option " + flag + " needs a value");
            }
            String value = args.get(++i);
            switch (flag) {
                case "--bind" -> {
                    HostPort bind = HostPort.parse("--bind", value);
                    bindHost = bind.host();
                    bindPort = bind.port();
                }
                case "--rcvbuf" -> rcvbuf = positiveInt(flag, value);
                case "--expect" -> expect = positiveLong(flag, value);
                case "--idle-timeout-ms" -> idleTimeoutMs = positiveLong(flag, value);
                case "--report" -> report = Path.of(value);
                case "--example" -> example = value;
                case "--variant" -> variant = value;
                case "--window" -> window = positiveLong(flag, value);
                default -> throw new IllegalArgumentException("unknown option " + flag);
            }
        }
        return new Config(bindHost, bindPort, rcvbuf, expect, idleTimeoutMs, report, example, variant, window);
    }

    /** A {@code HOST:PORT} option value. */
    public record HostPort(String host, int port) {

        /** Splits at the last colon and checks the port is 0..65535 (0 binds an ephemeral port); {@code flag} names the option in errors. */
        public static HostPort parse(String flag, String hostPort) {
            int colon = hostPort.lastIndexOf(':');
            if (colon <= 0) {
                throw new IllegalArgumentException(flag + " needs HOST:PORT, got '" + hostPort + "'");
            }
            String text = hostPort.substring(colon + 1);
            int port;
            try {
                port = Integer.parseInt(text);
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException(flag + " port must be a number, got " + text, e);
            }
            if (port < 0 || port > 65535) {
                throw new IllegalArgumentException(flag + " port out of range: " + port);
            }
            return new HostPort(hostPort.substring(0, colon), port);
        }
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
    public static final class HelpRequested extends RuntimeException {
        private static final long serialVersionUID = 1L;

        HelpRequested() {
            super("help requested", null, false, false);
        }
    }
}
