package io.patterncatalyst.lowlat.lockfree;

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
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLongArray;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.LockSupport;

/**
 * The line run: four tunnel cameras (four simulator instances, one UDP port each) feed one tracker.
 * One receive thread per camera decodes its datagrams and offers each scan to the shared
 * {@link Mailbox}; the tracker thread decides the lane, sends the divert command on the separate
 * {@link CommandChannel} and completes the parcel. The five threads are pinned to distinct cores.
 *
 * <p>The tracker owns every camera's {@link Completion} from the first scan on (see its ownership
 * rule): it is the only caller of {@code complete}, and each receive thread waits in {@code drain}
 * until the tracker has handled everything that camera published.
 */
final class LineRun {

    static final int CAMERAS = 4;
    /** Scanner reads below this confidence go to the exception lane for a person to look at. */
    private static final int MIN_CONFIDENCE_PERMILLE = 500;
    /** Encoder ticks between the scanner and the diverter: 1.2 m at the simulator's 1000 pulses per metre. */
    private static final long DIVERT_DISTANCE_TICKS = 1_200;
    private static final int MAILBOX_SLOTS = 1 << 14;

    private LineRun() {
    }

    static Mailbox mailboxFor(String variant) {
        return switch (variant) {
            case "blocking-queue" -> new Mailbox.Blocking(MAILBOX_SLOTS);
            case "agrona-mpsc" -> new Mailbox.Spinning(MAILBOX_SLOTS);
            default -> throw new IllegalArgumentException("--variant: blocking-queue | agrona-mpsc");
        };
    }

    /** A camera's receive-side hook: offer the scan, count it, and wait for the tracker at the end. */
    private static final class CameraHandler implements EventHandler<ParcelEvent> {
        private final int camera;
        private final Mailbox mailbox;
        private final AtomicLongArray handled;
        long published;
        long overflow;

        CameraHandler(int camera, Mailbox mailbox, AtomicLongArray handled) {
            this.camera = camera;
            this.mailbox = mailbox;
            this.handled = handled;
        }

        @Override
        public void onParcel(ParcelEvent event, Completion done) {
            if (mailbox.offer(Scan.of(camera, event))) {
                published++;
            } else {
                overflow++; // the mailbox is full: the parcel is lost, and the count shows it
            }
        }

        @Override
        public void drain(Completion done) {
            while (handled.getAcquire(camera) < published) {
                LockSupport.parkNanos(1_000_000); // after the run: a poll, not a spin
            }
        }
    }

    /** What one pass over the line measured; the receivers hold the per-camera recorders and completions. */
    private record Pass(LatencyRecorder endToEnd, List<EventReceiver<ParcelEvent>> receivers, List<CameraHandler> handlers,
            DivertListener diverter, long[] trackerCounts) {
    }

    /** Sends the cameras' parcels in-process (the warm-up): a real run is fed by the simulator instead. */
    private interface Feeder {
        void feed(List<InetSocketAddress> cameras, long perCamera) throws IOException;
    }

    static void execute(String variant, Args args) throws Exception {
        Path report = args.report();
        if (report != null && !LatencyRecorder.profileConfigured()) {
            throw new IllegalStateException("--report needs " + LatencyRecorder.PROFILE_ENV);
        }
        List<Integer> cpus = args.cpus(CAMERAS + 1);
        // A warm-up pass first: the same threads, sockets, queue and command path, fed in-process on
        // ephemeral ports and thrown away. Without it the first parcels of the measured pass wait for
        // class loading and the interpreter, a stall longer than the 4 MiB-capped socket buffer holds.
        long warmup = args.number("warmup-parcels-per-camera", 3_000);
        if (warmup > 0) {
            pass(variant, new int[CAMERAS], warmup, cpus, new Placement.Gate(CAMERAS + 1, 0, false), LineRun::synthetic, false);
        }
        int basePort = (int) args.number("base-port", 47300);
        int[] ports = new int[CAMERAS];
        for (int camera = 0; camera < CAMERAS; camera++) {
            ports[camera] = basePort + camera;
        }
        long perCamera = args.number("expect", 50_000);
        Pass pass = pass(variant, ports, perCamera, cpus, new Placement.Gate(CAMERAS + 1, args.number("hold-ms", 0)), null, true);

        long dropped = 0;
        long published = 0;
        long overflow = 0;
        for (int camera = 0; camera < CAMERAS; camera++) {
            dropped += pass.receivers().get(camera).dropped();
            published += pass.handlers().get(camera).published;
            overflow += pass.handlers().get(camera).overflow;
        }
        pass.endToEnd().addDropped(dropped);
        System.out.printf("line: handled %d of %d published, dropped %d, overflow %d, divert commands received %d%n", pass.trackerCounts()[0],
                published, dropped, overflow, pass.diverter().received());
        pass.endToEnd().printSummary();
        if (report != null) {
            writeReports(report, args, cpus, pass, published, overflow, dropped);
        }
    }

    /** Warm-up feeder: paced synthetic parcels to each camera from its own thread. */
    private static void synthetic(List<InetSocketAddress> cameras, long perCamera) throws IOException {
        List<Thread> senders = new ArrayList<>();
        for (InetSocketAddress camera : cameras) {
            senders.add(Thread.ofPlatform().name("warmup-feeder").unstarted(() -> {
                try (DatagramChannel channel = DatagramChannel.open(StandardProtocolFamily.INET)) {
                    channel.connect(camera);
                    ByteBuffer buffer = ByteBuffer.allocateDirect(256);
                    for (long seq = 0; seq < perCamera; seq++) {
                        ParcelEvent event = ParcelEvent.newBuilder().setSeq(seq).setIntendedEmitNs(System.nanoTime()).setEncoderTick(seq)
                                .setBarcode(String.format("%018d", seq)).setScanConfidencePermille(seq % 20 == 0 ? 400 : 990).build();
                        buffer.clear();
                        buffer.put(event.toByteArray()).flip();
                        channel.write(buffer);
                        LockSupport.parkNanos(200_000);
                    }
                } catch (IOException e) {
                    throw new UncheckedIOException(e);
                }
            }));
        }
        senders.forEach(Thread::start);
        for (Thread sender : senders) {
            try {
                sender.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("interrupted while feeding the warm-up", e);
            }
        }
    }

    /**
     * One pass: bind the cameras (port 0 binds an ephemeral port), start the five pinned threads and
     * run until every camera has seen {@code perCamera} parcels. {@code feeder} supplies the parcels
     * in-process; null leaves them to the simulator.
     */
    @SuppressWarnings("try") // the pin is held by the try block; the body needs no reference to it
    private static Pass pass(String variant, int[] ports, long perCamera, List<Integer> cpus, Placement.Gate gate, Feeder feeder,
            boolean announce) throws Exception {
        Mailbox mailbox = mailboxFor(variant);
        AtomicLongArray handled = new AtomicLongArray(CAMERAS);
        LatencyRecorder endToEnd = LatencyRecorder.singleThreaded(ClaimRun.EXAMPLE, variant);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        List<EventReceiver<ParcelEvent>> receivers = new ArrayList<>();
        List<CameraHandler> handlers = new ArrayList<>();
        long[] trackerCounts = new long[2]; // handled, exception lane: the tracker's, read after join

        DivertListener diverter = new DivertListener(ClaimRun.EXAMPLE, variant);
        try {
            for (int camera = 0; camera < CAMERAS; camera++) {
                Config config = Config.parse(List.of("--bind", "127.0.0.1:" + ports[camera], "--expect", Long.toString(perCamera),
                        "--idle-timeout-ms", "5000", "--example", ClaimRun.EXAMPLE, "--variant", variant));
                receivers.add(new EventReceiver<>(config, Decoder.protobuf()));
                handlers.add(new CameraHandler(camera, mailbox, handled));
            }
            try (CommandChannel commands = new CommandChannel(diverter.address())) {
                List<Thread> receiveThreads = new ArrayList<>();
                for (int camera = 0; camera < CAMERAS; camera++) {
                    int index = camera;
                    receiveThreads.add(Thread.ofPlatform().name("camera-" + camera).uncaughtExceptionHandler(Placement.recordTo(failure))
                            .unstarted(() -> {
                                try (Placement.Pin pin = gate.workerReady(cpus.get(index), "camera-" + index)) {
                                    receivers.get(index).run(handlers.get(index));
                                } catch (IOException e) {
                                    throw new UncheckedIOException(e);
                                }
                            }));
                }
                Thread tracker = Thread.ofPlatform().name("tracker").uncaughtExceptionHandler(Placement.recordTo(failure)).unstarted(() -> {
                    try (Placement.Pin pin = gate.workerReady(cpus.get(CAMERAS), "tracker")) {
                        track(mailbox, receivers, commands, endToEnd, handled, trackerCounts);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        throw new IllegalStateException("tracker interrupted", e);
                    }
                });
                List<InetSocketAddress> addresses = new ArrayList<>();
                for (EventReceiver<ParcelEvent> receiver : receivers) {
                    addresses.add(receiver.localAddress());
                    if (announce) {
                        System.out.println("line: camera listening on " + receiver.localAddress());
                    }
                }
                System.out.flush(); // bound: a script reading a redirected stdout waits on these lines
                receiveThreads.forEach(Thread::start);
                tracker.start();
                gate.release();
                if (feeder != null) {
                    feeder.feed(addresses, perCamera);
                }
                for (Thread thread : receiveThreads) {
                    thread.join();
                }
                while (!mailbox.offer(Scan.END)) {
                    LockSupport.parkNanos(1_000_000);
                }
                tracker.join();
            }
            awaitDiverter(diverter, trackerCounts[0]);
        } finally {
            for (EventReceiver<ParcelEvent> receiver : receivers) {
                receiver.close();
            }
            diverter.close(); // joins the listener: its recorder is safe to read
        }
        if (failure.get() != null) {
            throw new IllegalStateException("a thread failed", failure.get());
        }
        return new Pass(endToEnd, receivers, handlers, diverter, trackerCounts);
    }

    /** The tracker thread: decide the lane, send the command, complete the parcel. */
    private static void track(Mailbox mailbox, List<EventReceiver<ParcelEvent>> receivers, CommandChannel commands, LatencyRecorder endToEnd,
            AtomicLongArray handled, long[] counts) throws InterruptedException {
        long[] perCamera = new long[CAMERAS];
        for (Scan scan = mailbox.take(); scan != Scan.END; scan = mailbox.take()) {
            Lane lane = scan.confidencePermille() < MIN_CONFIDENCE_PERMILLE ? Lane.LANE_EXCEPTION
                    : Lane.forNumber(Lane.LANE_1_VALUE + Lanes.laneOf(scan.barcode()));
            if (lane == Lane.LANE_EXCEPTION) {
                counts[1]++;
            }
            DivertCommand command = DivertCommand.newBuilder().setSeq(scan.seq()).setLane(lane)
                    .setDeadlineEncoderTick(scan.encoderTick() + DIVERT_DISTANCE_TICKS).setDecidedNs(System.nanoTime()).build();
            try {
                commands.send(command);
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
            long doneNs = System.nanoTime();
            receivers.get(scan.camera()).completion().complete(scan.seq(), scan.intendedNs(), doneNs);
            endToEnd.record(doneNs - scan.intendedNs());
            counts[0]++;
            handled.setRelease(scan.camera(), ++perCamera[scan.camera()]);
        }
    }

    /** The last few command datagrams are still in flight when the data path stops. */
    private static void awaitDiverter(DivertListener diverter, long expected) {
        long deadline = System.nanoTime() + 5_000_000_000L;
        while (diverter.received() < expected && System.nanoTime() < deadline) {
            LockSupport.parkNanos(1_000_000);
        }
    }

    private static void writeReports(Path report, Args args, List<Integer> cpus, Pass pass, long published, long overflow, long dropped) {
        long[] trackerCounts = pass.trackerCounts();
        DivertListener diverter = pass.diverter();
        LatencyRecorder endToEnd = pass.endToEnd();
        List<EventReceiver<ParcelEvent>> receivers = pass.receivers();
        Map<String, Object> placement = Placement.placement(cpus);
        String notes = "line; cameras=" + CAMERAS + "; expect_per_camera=" + args.number("expect", 50_000) + "; published=" + published
                + "; overflow=" + overflow + "; handled=" + trackerCounts[0] + "; exception_lane=" + trackerCounts[1]
                + "; divert_received=" + diverter.received() + "; mailbox_slots=" + MAILBOX_SLOTS;
        Map<String, Object> aggregate = RuntimeInfo.jvm();
        if (!placement.isEmpty()) {
            aggregate.put("placement", placement);
        }
        aggregate.put("counters", RuntimeInfo.counters(Map.of("handled", trackerCounts[0], "published", published, "overflow", overflow,
                "dropped", dropped, "divert_received", diverter.received())));
        endToEnd.writeReport(report, notes, null, aggregate);
        System.out.println("report: " + report);
        for (int camera = 0; camera < CAMERAS; camera++) {
            EventReceiver<ParcelEvent> receiver = receivers.get(camera);
            Map<String, Object> runtime = receiver.runtime();
            if (!placement.isEmpty()) {
                runtime.put("placement", placement);
            }
            Path path = Report.sibling(report, "-camera" + camera);
            receiver.recorder().writeReport(path, notes + "; camera=" + camera, null, runtime);
            System.out.println("report: " + path);
        }
        Map<String, Object> divertRuntime = RuntimeInfo.jvm();
        if (!placement.isEmpty()) {
            divertRuntime.put("placement", placement);
        }
        Path divert = Report.sibling(report, "-divert");
        diverter.latency().writeReport(divert, notes + "; divert latency is the tracker's decision to the command's arrival", null, divertRuntime);
        System.out.println("report: " + divert);
    }
}
