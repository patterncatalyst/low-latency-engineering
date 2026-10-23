package io.patterncatalyst.lowlat.eliminating;

import org.agrona.collections.Long2LongHashMap;
import org.openjdk.jol.info.ClassLayout;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.State;

/** Build wiring for Ch9 (S4): proves Agrona, JOL and JMH resolve and compile. Replaced in S5. */
@State(Scope.Thread)
public class Wiring {
    private final Long2LongHashMap map = new Long2LongHashMap(-1L);

    /** Inserts and reads back one key through the Agrona primitive map. */
    @Benchmark
    public long putGet() {
        map.put(1L, 42L);
        return map.get(1L);
    }

    /** Instance size of a plain object as JOL reports it. */
    public static long instanceSize(Class<?> type) {
        return ClassLayout.parseClass(type).instanceSize();
    }
}
