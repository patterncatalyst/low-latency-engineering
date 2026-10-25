package io.patterncatalyst.lowlat.ch11;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import jdk.jfr.Recording;
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordingFile;

/**
 * What still pins a virtual thread. Two cases, each in its own Flight Recorder recording with the
 * {@code jdk.VirtualThreadPinned} threshold at 0:
 * <ul>
 *   <li>a virtual thread blocks inside a {@code synchronized} block (JEP 491, JDK 24: it unmounts, no event);</li>
 *   <li>a virtual thread blocks in a Java upcall that a native function (libc {@code qsort}) is running, so a native
 *       frame sits between the virtual thread and its carrier (it still pins, one event per block).</li>
 * </ul>
 * The recordings are written to a temporary file, read back and deleted; only the counts are kept.
 */
final class PinningRun {

    private static final String EVENT = "jdk.VirtualThreadPinned";

    private PinningRun() {
    }

    static Run execute(int tasks, long blockMs) throws Exception {
        long[] synchronizedNs = new long[tasks];
        long[] nativeNs = new long[tasks];
        long inSynchronized = recorded(() -> blockInSynchronized(tasks, blockMs, synchronizedNs));
        long inNative = recorded(() -> blockInNativeFrame(tasks, blockMs, nativeNs));
        Map<String, Long> counters = new HashMap<>();
        counters.put("tasks_per_case", (long) tasks);
        counters.put("block_ms", blockMs);
        counters.put("pinned_events_synchronized", inSynchronized);
        counters.put("pinned_events_native_frame", inNative);
        counters.put("jfr_threshold_ms", 0L);
        String notes = "pinning; model=virtual-thread; jdk.VirtualThreadPinned counts, synchronized block against a native frame (qsort upcall); "
                + "sample=time a virtual thread spent blocked in the synchronized block; JFR files are temporary and not kept";
        return Run.of(synchronizedNs, counters, List.of(), null, notes);
    }

    private interface Body {
        void run() throws Exception;
    }

    /** Runs {@code body} inside a recording and returns how many pinned events it holds. */
    private static long recorded(Body body) throws Exception {
        Path file = Files.createTempFile("pinned", ".jfr");
        try (Recording recording = new Recording()) {
            recording.enable(EVENT).withThreshold(Duration.ZERO);
            recording.start();
            body.run();
            recording.stop();
            recording.dump(file);
            long count = 0;
            for (RecordedEvent event : RecordingFile.readAllEvents(file)) {
                if (EVENT.equals(event.getEventType().getName())) {
                    count++;
                }
            }
            return count;
        } finally {
            Files.deleteIfExists(file);
        }
    }

    private static void blockInSynchronized(int tasks, long blockMs, long[] ns) throws InterruptedException {
        List<Thread> threads = new java.util.ArrayList<>();
        for (int i = 0; i < tasks; i++) {
            int index = i;
            Object monitor = new Object(); // one monitor each: the case is blocking while holding one, not contending for one
            threads.add(Thread.ofVirtual().start(() -> {
                long t0 = System.nanoTime();
                synchronized (monitor) {
                    try {
                        Thread.sleep(blockMs);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                }
                ns[index] = System.nanoTime() - t0;
            }));
        }
        for (Thread t : threads) {
            t.join();
        }
    }

    private static long upcallBlockMs;

    /** The comparator qsort calls: it blocks, with qsort's native frame below it on the stack. */
    @SuppressWarnings("unused") // reached through a method handle
    private static int compare(MemorySegment a, MemorySegment b) {
        try {
            Thread.sleep(upcallBlockMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return Integer.compare(a.get(ValueLayout.JAVA_INT, 0), b.get(ValueLayout.JAVA_INT, 0));
    }

    @SuppressWarnings("restricted") // the FFM calls need --enable-native-access, which the run passes
    private static void blockInNativeFrame(int tasks, long blockMs, long[] ns) throws Exception {
        upcallBlockMs = blockMs;
        Linker linker = Linker.nativeLinker();
        MethodHandle qsort = linker.downcallHandle(linker.defaultLookup().find("qsort").orElseThrow(),
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS, ValueLayout.JAVA_LONG, ValueLayout.JAVA_LONG, ValueLayout.ADDRESS));
        MethodHandle compare = MethodHandles.lookup().findStatic(PinningRun.class, "compare",
                MethodType.methodType(int.class, MemorySegment.class, MemorySegment.class));
        FunctionDescriptor comparator = FunctionDescriptor.of(ValueLayout.JAVA_INT,
                ValueLayout.ADDRESS.withTargetLayout(ValueLayout.JAVA_INT), ValueLayout.ADDRESS.withTargetLayout(ValueLayout.JAVA_INT));
        try (Arena arena = Arena.ofShared()) {
            MemorySegment stub = linker.upcallStub(compare, comparator, arena);
            List<Thread> threads = new java.util.ArrayList<>();
            for (int i = 0; i < tasks; i++) {
                int index = i;
                threads.add(Thread.ofVirtual().start(() -> {
                    try (Arena mine = Arena.ofConfined()) {
                        MemorySegment values = mine.allocate(ValueLayout.JAVA_INT, 2);
                        values.setAtIndex(ValueLayout.JAVA_INT, 0, 2);
                        values.setAtIndex(ValueLayout.JAVA_INT, 1, 1);
                        long t0 = System.nanoTime();
                        qsort.invokeExact(values, 2L, 4L, stub);
                        ns[index] = System.nanoTime() - t0;
                    } catch (Throwable t) {
                        throw new IllegalStateException("qsort downcall failed", t);
                    }
                }));
            }
            for (Thread t : threads) {
                t.join();
            }
        }
    }
}
