package io.patterncatalyst.lowlat.lockfree;

import static org.openjdk.jcstress.annotations.Expect.ACCEPTABLE;
import static org.openjdk.jcstress.annotations.Expect.FORBIDDEN;

import org.openjdk.jcstress.annotations.Actor;
import org.openjdk.jcstress.annotations.JCStressTest;
import org.openjdk.jcstress.annotations.Outcome;
import org.openjdk.jcstress.annotations.State;
import org.openjdk.jcstress.infra.results.II_Result;

/**
 * The induction-gap test with volatile flags (sequentially consistent): each station raises its flag,
 * then reads the other's. Both reading 0 means both induct into one gap, and the Java memory model
 * forbids it for volatile accesses.
 */
@JCStressTest
@Outcome(id = "0, 0", expect = FORBIDDEN, desc = "Both stations missed the other's claim: forbidden for volatile.")
@Outcome(id = {"0, 1", "1, 0", "1, 1"}, expect = ACCEPTABLE, desc = "At least one station saw the other.")
@State
public class StoreBufferVolatile {

    volatile int a;
    volatile int b;

    @Actor
    public void stationA(II_Result r) {
        a = 1;
        r.r1 = b;
    }

    @Actor
    public void stationB(II_Result r) {
        b = 1;
        r.r2 = a;
    }
}
