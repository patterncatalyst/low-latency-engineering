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

/** Spawns the built C++ line-simulator at 1 kHz for 2 s into a LineReceiver on UDP 47103. */
class SimulatorIntegrationTest {

    private static final int PORT = 47103;

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
}
