package io.patterncatalyst.lowlat.lockfree;

import static org.openjdk.jcstress.annotations.Expect.ACCEPTABLE;

import org.openjdk.jcstress.annotations.Actor;
import org.openjdk.jcstress.annotations.JCStressTest;
import org.openjdk.jcstress.annotations.Outcome;
import org.openjdk.jcstress.annotations.State;
import org.openjdk.jcstress.infra.results.I_Result;

/** Wiring-only jcstress test (S4): one actor, one outcome. The induction-gap litmus tests come in S6. */
@JCStressTest
@Outcome(id = "1", expect = ACCEPTABLE, desc = "The store is visible to the same actor.")
@State
public class WiringLitmus {
    volatile int x;

    @Actor
    public void actor(I_Result r) {
        x = 1;
        r.r1 = x;
    }
}
