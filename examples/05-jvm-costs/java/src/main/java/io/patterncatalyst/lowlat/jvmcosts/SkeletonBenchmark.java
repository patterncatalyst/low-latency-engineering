package io.patterncatalyst.lowlat.jvmcosts;

import org.openjdk.jmh.annotations.Benchmark;

/** Proves the JMH annotation processor and the shaded benchmarks.jar; replaced by the real benchmarks. */
public class SkeletonBenchmark {
    @Benchmark
    public int noop() {
        return Skeleton.NAME.length();
    }
}
