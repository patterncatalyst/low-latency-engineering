package io.patterncatalyst.lowlat.ch11;

import io.patterncatalyst.lowlat.line.Completion;
import io.patterncatalyst.lowlat.line.Config;
import io.patterncatalyst.lowlat.line.Decoder;
import io.patterncatalyst.lowlat.line.EventHandler;
import io.patterncatalyst.lowlat.line.EventReceiver;
import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.v1.DivertCommand;
import io.patterncatalyst.lowlat.line.v1.Lane;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import io.patterncatalyst.lowlat.measure.LatencyRecorder;
import io.patterncatalyst.lowlat.measure.RuntimeInfo;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.InetSocketAddress;
import java.net.StandardProtocolFamily;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.LongAdder;
import java.util.concurrent.locks.LockSupport;
import java.util.concurrent.locks.ReentrantLock;
import net.openhft.affinity.Affinity;

/**
 * The line run: one simulator instance feeds a UDP port. For every scan the receive thread starts a lookup task
 * that waits 2 ms (the warehouse management system's answer, a timer in this process), then decides the lane,
 * sends the divert command on the separate command socket and completes the parcel. Who holds the wait is the
 * variant: a platform thread per lookup, or a virtual thread per lookup
 * ({@code Executors.newVirtualThreadPerTaskExecutor()}).
 */
final class LineRun {

    static final long LOOKUP_WAIT_MS = 2;
    private static final int MIN_CONFIDENCE_PERMILLE = 500;
    private static final long DIVERT_DISTANCE_TICKS = 1_200;

    private LineRun() {
    }

    /** The hook the receive loop calls per parcel; each parcel gets its own task. */
    private static final class LookupHandler implements EventHandler<ParcelEvent> {
        private final ExecutorService tasks;
        private final CommandChannel commands;
        private final ReentrantLock completing = new ReentrantLock();
        long started; // the receive thread writes it; main reads it after rx.join()
        final LongAdder decided = new LongAdder();
        final LongAdder exceptionLane = new LongAdder();
        private volatile Throwable failure;

        LookupHandler(ExecutorService tasks, CommandChannel commands) {
            this.tasks = tasks;
            this.commands = commands;
        }

        @Override
        public void onParcel(ParcelEvent event, Completion done) {
            started++;
            long seq = event.getSeq();
            long intendedNs = event.getIntendedEmitNs();
            long encoderTick = event.getEncoderTick();
            int confidence = event.getScanConfidencePermille();
            String barcode = event.getBarcode();
            tasks.execute(() -> {
                try {
                    Thread.sleep(LOOKUP_WAIT_MS); // the WMS answer; the thread (platform or virtual) holds the wait
                    Lane lane = confidence < MIN_CONFIDENCE_PERMILLE ? Lane.LANE_EXCEPTION
                            : Lane.forNumber(Lane.LANE_1_VALUE + Lanes.laneOf(barcode));
                    if (lane == Lane.LANE_EXCEPTION) {
                        exceptionLane.increment();
                    }
                    DivertCommand command = DivertCommand.newBuilder().setSeq(seq).setLane(lane)
                            .setDeadlineEncoderTick(encoderTick + DIVERT_DISTANCE_TICKS).setDecidedNs(System.nanoTime()).build();
                    commands.send(command);
                    long doneNs = System.nanoTime();
                    // Completion is single-writer: the lookup tasks take turns at it.
                    completing.lock();
                    try {
                        done.complete(seq, intendedNs, doneNs);
                    } finally {
                        completing.unlock();
                    }
                    decided.increment();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } catch (IOException e) {
                    failure = new UncheckedIOException(e);
                } catch (RuntimeException e) {
                    failure = e;
                }
            });
        }

        /** The loop has ended: wait for every lookup that is still in flight. */
        @Override
        public void drain(Completion done) {
            tasks.close(); // shutdown, then waits for every submitted task
        }

        Throwable failure() {
            return failure;
        }
    }

    /** Platform threads for the lookups, started from a pinned thread, drop the inherited pin first. */
    private static ThreadFactory unpinnedPlatform() {
        return task -> Thread.ofPlatform().unstarted(() -> {
            Affinity.resetToBaseAffinity();
            task.run();
        });
    }

    /** Runs {@code perCamera} synthetic parcels at about 10 kHz into {@code target}: the warm-up feeder. */
    private static void synthetic(InetSocketAddress target, long parcels) throws IOException {
        try (DatagramChannel channel = DatagramChannel.open(StandardProtocolFamily.INET)) {
            channel.connect(target);
            ByteBuffer buffer = ByteBuffer.allocateDirect(256);
            for (long seq = 0; seq < parcels; seq++) {
                ParcelEvent event = ParcelEvent.newBuilder().setSeq(seq).setIntendedEmitNs(System.nanoTime()).setEncoderTick(seq)
                        .setBarcode(String.format("%018d", 300_000_000_000_000_000L + seq)).setScanConfidencePermille(seq % 20 == 0 ? 400 : 990)
                        .build();
                buffer.clear();
                buffer.put(event.toByteArray()).flip();
                channel.write(buffer);
                LockSupport.parkNanos(100_000);
            }
        }
    }

    private record Pass(LatencyRecorder endToEnd, EventReceiver<ParcelEvent> receiver, LookupHandler handler, DivertListener diverter,
            Placement.Gate gate) {
    }

    static void execute(Run.Kind kind, int basePort, long expect, int cpu, long holdMs, long warmupParcels, Path report) throws Exception {
        if (warmupParcels > 0) {
            // The same threads, sockets and command path, fed in-process on an ephemeral port and thrown away, unpinned: it loads
            // the classes, compiles the loop and starts the virtual-thread carriers before any thread is pinned.
            pass(kind, 0, warmupParcels, -1, 0, false, true);
        }
        Pass pass = pass(kind, basePort, expect, cpu, holdMs, true, false);
        EventReceiver<ParcelEvent> receiver = pass.receiver();
        LookupHandler handler = pass.handler();
        long dropped = receiver.dropped();
        pass.endToEnd().addDropped(dropped);
        System.out.printf("line: received %d of %d, dropped %d, decided %d, divert commands received %d%n", receiver.received(), expect,
                dropped, handler.decided.sum(), pass.diverter().received());
        pass.endToEnd().printSummary();
        if (report == null) {
            return;
        }
        List<Integer> pinned = cpu >= 0 ? List.of(cpu) : List.of();
        Map<String, Object> placement = Placement.placement(pinned);
        String notes = "line; expect=" + expect + "; received=" + receiver.received() + "; decided=" + handler.decided.sum()
                + "; exception_lane=" + handler.exceptionLane.sum() + "; divert_received=" + pass.diverter().received() + "; lookup_wait_ms="
                + LOOKUP_WAIT_MS + "; model=" + kind.variant;
        Map<String, Object> runtime = RuntimeInfo.jvm();
        if (!placement.isEmpty()) {
            runtime.put("placement", placement);
        }
        runtime.put("counters", RuntimeInfo.counters(Map.of("received", receiver.received(), "dropped", dropped, "decided",
                handler.decided.sum(), "tasks_started", handler.started, "divert_received", pass.diverter().received(),
                "start_skew_ns", pass.gate().startSkewNs())));
        pass.endToEnd().writeReport(report, notes, null, runtime);
        System.out.println("report: " + report);
        Map<String, Object> divertRuntime = RuntimeInfo.jvm();
        if (!placement.isEmpty()) {
            divertRuntime.put("placement", placement);
        }
        Path divert = sibling(report, "-divert");
        pass.diverter().latency().writeReport(divert, notes + "; divert latency is the decision to the command's arrival", null, divertRuntime);
        System.out.println("report: " + divert);
    }

    static Path sibling(Path report, String suffix) {
        String name = report.getFileName().toString();
        int dot = name.lastIndexOf('.');
        String stem = dot < 0 ? name : name.substring(0, dot);
        String extension = dot < 0 ? "" : name.substring(dot);
        return report.resolveSibling(stem + suffix + extension);
    }

    private static Pass pass(Run.Kind kind, int port, long expect, int cpu, long holdMs, boolean announce, boolean feed) throws Exception {
        String variant = kind.variant;
        DivertListener diverter = new DivertListener(Run.EXAMPLE, variant);
        ExecutorService tasks = kind == Run.Kind.VIRTUAL ? Executors.newVirtualThreadPerTaskExecutor()
                : Executors.newThreadPerTaskExecutor(unpinnedPlatform());
        Config config = Config.parse(List.of("--bind", "127.0.0.1:" + port, "--expect", Long.toString(expect), "--idle-timeout-ms", "5000",
                "--example", Run.EXAMPLE, "--variant", variant));
        EventReceiver<ParcelEvent> receiver = new EventReceiver<>(config, Decoder.protobuf());
        Placement.Gate gate = new Placement.Gate(1, holdMs, announce);
        Throwable[] failure = new Throwable[1];
        try (CommandChannel commands = new CommandChannel(diverter.address())) {
            LookupHandler handler = new LookupHandler(tasks, commands);
            Thread rx = Thread.ofPlatform().name("receive").uncaughtExceptionHandler((t, e) -> failure[0] = e).unstarted(() -> {
                try (Placement.Pin _ = gate.workerReady(cpu, "receive")) {
                    receiver.run(handler);
                } catch (IOException e) {
                    throw new UncheckedIOException(e);
                }
            });
            if (announce) {
                System.out.println("line: listening on " + receiver.localAddress());
                System.out.flush();
            }
            rx.start();
            gate.release();
            if (feed) {
                synthetic(receiver.localAddress(), expect);
            }
            rx.join();
            long deadline = System.nanoTime() + 5_000_000_000L;
            while (diverter.received() < handler.decided.sum() && System.nanoTime() < deadline) {
                LockSupport.parkNanos(1_000_000);
            }
            if (failure[0] != null) {
                throw new IllegalStateException("the receive thread failed", failure[0]);
            }
            if (handler.failure() != null) {
                throw new IllegalStateException("a lookup task failed", handler.failure());
            }
            diverter.close();
            LatencyRecorder endToEnd = receiver.recorder();
            return new Pass(endToEnd, receiver, handler, diverter, gate);
        } finally {
            receiver.close();
            diverter.close();
        }
    }
}
