package io.patterncatalyst.lowlat.ch14;

/** Policy changes for the calling thread. A failing call throws {@link com.sun.jna.LastErrorException} (EPERM without privilege). */
public final class Sched {

    private Sched() {
    }

    /** The calling thread's policy ({@link Libc#SCHED_OTHER}, {@link Libc#SCHED_FIFO}, ...). */
    public static int policy() {
        return Libc.INSTANCE.sched_getscheduler(0);
    }

    /** Moves the calling thread to SCHED_FIFO at {@code priority} (1..99); needs CAP_SYS_NICE or RLIMIT_RTPRIO. */
    public static void fifo(int priority) {
        if (priority < 1 || priority > 99) {
            throw new IllegalArgumentException("SCHED_FIFO priority is 1..99: " + priority);
        }
        Libc.INSTANCE.sched_setscheduler(0, Libc.SCHED_FIFO, new Libc.SchedParam(priority));
    }

    /** The kernel thread id of the calling thread (what chrt -p and /proc/self/task take). */
    public static int tid() {
        return Libc.INSTANCE.gettid();
    }
}
