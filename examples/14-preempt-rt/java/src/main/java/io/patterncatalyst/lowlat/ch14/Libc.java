package io.patterncatalyst.lowlat.ch14;

import com.sun.jna.LastErrorException;
import com.sun.jna.Library;
import com.sun.jna.Native;
import com.sun.jna.Structure;

/**
 * The scheduler calls the JDK does not expose. Java has no API for a thread's scheduling policy, so this is the
 * one non-idiomatic construct in the module: a JNA mapping of the C library. {@code pid 0} means the calling
 * thread on Linux (sched_setscheduler(2)), so the policy applies to the hot thread only and the rest of the JVM
 * stays SCHED_OTHER.
 */
public interface Libc extends Library {

    int SCHED_OTHER = 0;
    int SCHED_FIFO = 1;

    /** struct sched_param: one int. */
    @Structure.FieldOrder("sched_priority")
    class SchedParam extends Structure {
        public int sched_priority;

        public SchedParam() {
        }

        public SchedParam(int priority) {
            this.sched_priority = priority;
        }
    }

    /** Throws {@link LastErrorException} (errno in {@code getErrorCode()}) when the call returns -1. */
    int sched_setscheduler(int pid, int policy, SchedParam param) throws LastErrorException;

    /** Throws {@link LastErrorException} when the call returns -1. */
    int sched_getscheduler(int pid) throws LastErrorException;

    /** glibc has had a gettid() wrapper since 2.30. */
    int gettid();

    /** The mapping, loaded once. */
    Libc INSTANCE = Native.load("c", Libc.class);
}
