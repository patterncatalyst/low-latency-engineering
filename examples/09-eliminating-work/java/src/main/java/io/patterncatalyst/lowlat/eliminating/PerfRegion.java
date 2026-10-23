package io.patterncatalyst.lowlat.eliminating;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

/**
 * The counted region of {@code perf stat --control} (examples/_lib/lib.sh {@code perf_region}): when verify.sh runs a
 * JVM under perf_region, LOWLAT_PERF_CTL and LOWLAT_PERF_ACK name two FIFOs. {@link #enable} and {@link #disable}
 * bracket the measured loop, so JVM start-up, JIT and setup are not counted. Without the variables the region
 * is a no-op.
 */
final class PerfRegion {

    private final Path ctl;
    private final Path ack;

    private PerfRegion(Path ctl, Path ack) {
        this.ctl = ctl;
        this.ack = ack;
    }

    static PerfRegion open() {
        String c = System.getenv("LOWLAT_PERF_CTL");
        String a = System.getenv("LOWLAT_PERF_ACK");
        return c == null || a == null ? new PerfRegion(null, null) : new PerfRegion(Path.of(c), Path.of(a));
    }

    void enable() throws IOException {
        send("enable\n");
    }

    void disable() throws IOException {
        send("disable\n");
    }

    /** Tells perf_region how many operations the counted region covered (the divisor of per_op). */
    static void reportOps(long ops) throws IOException {
        String file = System.getenv("LOWLAT_OPS_FILE");
        if (file != null) {
            Files.writeString(Path.of(file), ops + "\n");
        }
    }

    private void send(String word) throws IOException {
        if (ctl == null) {
            return;
        }
        Files.write(ctl, word.getBytes(StandardCharsets.US_ASCII), StandardOpenOption.WRITE);
        try (RandomAccessFile in = new RandomAccessFile(ack.toFile(), "r")) { // blocks until perf answers "ack"
            in.readLine();
        }
    }
}
