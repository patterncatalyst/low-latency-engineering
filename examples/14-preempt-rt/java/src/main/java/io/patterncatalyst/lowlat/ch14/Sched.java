package io.patterncatalyst.lowlat.ch14;

import com.sun.jna.Native;

/** Policy changes for the calling thread, with errno turned into exceptions. */
public final class Sched {

    private Sched() {
    }

    /** The calling thread's policy ({@link Libc#SCHED_OTHER}, {@link Libc#SCHED_FIFO}, ...). */
    public static int policy() {
        int policy = Libc.INSTANCE.sched_getscheduler(0);
        if (policy < 0) {
            throw new IllegalStateException("sched_getscheduler failed, errno " + Native.getLastError());
        }
        return policy;
    }

    /** Moves the calling thread to SCHED_FIFO at {@code priority} (1..99); needs CAP_SYS_NICE or RLIMIT_RTPRIO. */
    public static void fifo(int priority) {
        if (priority < 1 || priority > 99) {
            throw new IllegalArgumentException("SCHED_FIFO priority is 1..99: " + priority);
        }
        if (Libc.INSTANCE.sched_setscheduler(0, Libc.SCHED_FIFO, new Libc.SchedParam(priority)) != 0) {
            throw new IllegalStateException("sched_setscheduler(SCHED_FIFO, " + priority + ") failed, errno " + Native.getLastError());
        }
    }

    /** The kernel thread id of the calling thread (what chrt -p and /proc/self/task take). */
    public static int tid() {
        return Libc.INSTANCE.gettid();
    }
}
