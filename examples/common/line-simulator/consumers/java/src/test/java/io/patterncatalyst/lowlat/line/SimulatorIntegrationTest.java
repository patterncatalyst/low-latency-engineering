package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

/** Spawns the built C++ line-simulator into a LineReceiver on UDP 47103 (protobuf) or 47106 (flat). */
class SimulatorIntegrationTest {

    private static final int PORT = 47103;
    private static final int FLAT_PORT = 47106;

    @Test
    void receivesTwoThousandParcelsWithoutLoss() throws Exception {
        Path examples = Path.of(System.getProperty("lowlat.examples.dir", "../../../..")).toAbsolutePath().normalize();
        Path simulator = examples.resolve("build/release/common/line-simulator/line-simulator");
        Assumptions.assumeTrue(Files.isExecutable(simulator),
                "line-simulator not built (" + simulator + "); run cmake --preset release first");

        Config config = Config.parse(List.of("--bind", "127.0.0.1:" + PORT, "--expect", "2000",
                "--idle-timeout-ms", "5000"));
        try (LineReceiver receiver = new LineReceiver(config)) {
            FutureTask<LineReceiver.StopReason> receive = new FutureTask<>(receiver::run);
            Thread loop = Thread.ofPlatform().name("test-consumer").start(receive);

            Process sim = new ProcessBuilder(simulator.toString(), "--rate", "1000", "--duration", "2",
                    "--dest", "127.0.0.1:" + PORT, "--quiet").inheritIO().start();
            assertTrue(sim.waitFor(30, TimeUnit.SECONDS), "simulator did not finish");
            loop.join(TimeUnit.SECONDS.toMillis(15));
            if (loop.isAlive()) {
                receiver.stop();
                loop.join();
            }

            assertEquals(Future.State.SUCCESS, receive.state(), "consumer failed (negative latency?)");
            assertEquals(LineReceiver.StopReason.EXPECTED, receive.resultNow());
            assertEquals(2000, receiver.received());
            assertEquals(0, receiver.gaps().dropped());
            assertEquals(0, receiver.gaps().reordered());
            assertEquals(2000, receiver.recorder().histogram().getTotalCount());
            assertTrue(receiver.recorder().histogram().getMinValue() >= 0, "negative latency recorded");
        }
    }

    /** The simulator's flat wire into an EventReceiver with the flat decoder, split at parcel 500. */
    @Test
    void receivesTheFlatWireInTwoWindows() throws Exception {
        Path examples = Path.of(System.getProperty("lowlat.examples.dir", "../../../..")).toAbsolutePath().normalize();
        Path simulator = examples.resolve("build/release/common/line-simulator/line-simulator");
        Assumptions.assumeTrue(Files.isExecutable(simulator),
                "line-simulator not built (" + simulator + "); run cmake --preset release first");

        Config config = Config.parse(List.of("--bind", "127.0.0.1:" + FLAT_PORT, "--expect", "1000",
                "--idle-timeout-ms", "5000", "--window", "500", "--variant", "flat"));
        try (EventReceiver<FlatParcel> receiver = new EventReceiver<>(config, new FlatParcel.FlatDecoder())) {
            FutureTask<EventReceiver.StopReason> receive = new FutureTask<>(() -> receiver.run(
                    (view, done) -> done.complete(view.seq(), view.intendedEmitNs(), System.nanoTime())));
            Thread loop = Thread.ofPlatform().name("test-flat-consumer").start(receive);

            Process sim = new ProcessBuilder(simulator.toString(), "--rate", "1000", "--duration", "1",
                    "--wire", "flat", "--dest", "127.0.0.1:" + FLAT_PORT, "--quiet").inheritIO().start();
            assertTrue(sim.waitFor(30, TimeUnit.SECONDS), "simulator did not finish");
            loop.join(TimeUnit.SECONDS.toMillis(15));
            if (loop.isAlive()) {
                receiver.stop();
                loop.join();
            }

            assertEquals(Future.State.SUCCESS, receive.state());
            assertEquals(1000, receiver.received());
            assertEquals(0, receiver.malformed());
            assertEquals(0, receiver.dropped());
            assertEquals(500, receiver.windows().first().histogram().getTotalCount());
            assertEquals(500, receiver.windows().steady().histogram().getTotalCount());
            assertEquals(1000, receiver.recorder().histogram().getTotalCount());
        }
    }
}
