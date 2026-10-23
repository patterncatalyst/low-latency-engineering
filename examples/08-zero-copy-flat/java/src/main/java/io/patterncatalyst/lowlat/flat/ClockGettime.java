package io.patterncatalyst.lowlat.flat;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemoryLayout.PathElement;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.StructLayout;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.VarHandle;

/**
 * {@code int clock_gettime(clockid_t, struct timespec *)} called through the Foreign Function &amp;
 * Memory API, in two linkages of the same C function:
 *
 * <ul>
 *   <li>{@link #standard()}: a normal downcall. The thread state changes from Java to native
 *       and back around the call (so the JVM can reach a safepoint while it runs).
 *   <li>{@link #critical()}: {@code Linker.Option.critical(false)}. The call is a short leaf: no
 *       thread-state transition, no callbacks, and no heap segments as arguments. It is faster, and
 *       the caller promises that the callee is quick, never blocks and never calls back into Java.
 * </ul>
 *
 * <p>The {@link FunctionDescriptor} is written by hand. {@code jextract}, which generates such
 * bindings from the header, has only early-access builds, and the project does not use
 * prerelease tools. A hand-written descriptor for one function is two lines, and the layout of
 * {@code struct timespec} below is the whole of what jextract would have produced.
 *
 * <p>One instance per thread: the timespec it reads into is a confined segment.
 */
public final class ClockGettime implements AutoCloseable {

    /** {@code CLOCK_MONOTONIC} in {@code <time.h>} on Linux; the clock {@code System.nanoTime()} reads. */
    public static final int CLOCK_MONOTONIC = 1;

    /** {@code struct timespec} on LP64 Linux: {@code time_t} and {@code long} are both 64 bits. */
    private static final StructLayout TIMESPEC = MemoryLayout.structLayout(
            JAVA_LONG.withName("tv_sec"),
            JAVA_LONG.withName("tv_nsec"));

    private static final VarHandle TV_SEC = TIMESPEC.varHandle(PathElement.groupElement("tv_sec"));
    private static final VarHandle TV_NSEC = TIMESPEC.varHandle(PathElement.groupElement("tv_nsec"));

    private static final FunctionDescriptor DESCRIPTOR = FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS);

    // static final, so the JIT treats the handles as constants and inlines the native call.
    private static final MethodHandle STANDARD = link();
    private static final MethodHandle CRITICAL = link(Linker.Option.critical(false));

    private final Arena arena = Arena.ofConfined();
    private final MemorySegment timespec = arena.allocate(TIMESPEC);

    // downcallHandle is a restricted method: the runtime flag --enable-native-access (set by every
    // script and by surefire) grants it; javac's lint would still warn, and -Werror is on.
    @SuppressWarnings("restricted")
    private static MethodHandle link(Linker.Option... options) {
        Linker linker = Linker.nativeLinker();
        MemorySegment symbol = linker.defaultLookup().find("clock_gettime")
                .orElseThrow(() -> new IllegalStateException("clock_gettime not found in the default lookup"));
        return linker.downcallHandle(symbol, DESCRIPTOR, options);
    }

    /** {@code CLOCK_MONOTONIC} in nanoseconds through the standard downcall. */
    public long standard() {
        return read(STANDARD);
    }

    /** {@code CLOCK_MONOTONIC} in nanoseconds through the critical downcall. */
    public long critical() {
        return read(CRITICAL);
    }

    private long read(MethodHandle clockGettime) {
        int status;
        try {
            // invokeExact: the call site's types must match the descriptor exactly.
            status = (int) clockGettime.invokeExact(CLOCK_MONOTONIC, timespec);
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable e) { // invokeExact is declared to throw it; a plain downcall throws nothing checked
            throw new AssertionError(e);
        }
        if (status != 0) {
            throw new IllegalStateException("clock_gettime returned " + status);
        }
        return (long) TV_SEC.get(timespec, 0L) * 1_000_000_000L + (long) TV_NSEC.get(timespec, 0L);
    }

    @Override
    public void close() {
        arena.close();
    }
}
