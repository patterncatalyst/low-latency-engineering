package io.patterncatalyst.lowlat.ch13;

/** Wiring skeleton: the CPU count the JVM reports (quota- and cpuset-aware inside a container). */
public final class CpuProbe {

    private CpuProbe() {}

    public static int availableProcessors() {
        return Runtime.getRuntime().availableProcessors();
    }
}
