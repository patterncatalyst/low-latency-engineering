package io.patterncatalyst.lowlat.lockfree;

import static org.openjdk.jcstress.annotations.Expect.ACCEPTABLE;
import static org.openjdk.jcstress.annotations.Expect.ACCEPTABLE_INTERESTING;

import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import org.openjdk.jcstress.annotations.Actor;
import org.openjdk.jcstress.annotations.JCStressTest;
import org.openjdk.jcstress.annotations.Outcome;
import org.openjdk.jcstress.annotations.State;
import org.openjdk.jcstress.infra.results.II_Result;

/**
 * The induction-gap test with {@code setRelease} / {@code getAcquire} (the {@code VarHandle} modes
 * that map to C++ {@code memory_order_release} / {@code acquire}): release/acquire orders each station's
 * earlier accesses against its later ones in one direction only, so a store may sit in the store buffer
 * while the next load runs. Both reading 0 is allowed, and observed on x86-64.
 */
@JCStressTest
@Outcome(id = "0, 0", expect = ACCEPTABLE_INTERESTING, desc = "Both stations missed the other's claim: allowed for release/acquire.")
@Outcome(id = {"0, 1", "1, 0", "1, 1"}, expect = ACCEPTABLE, desc = "At least one station saw the other.")
@State
public class StoreBufferAcquireRelease {

    private static final VarHandle A;
    private static final VarHandle B;

    static {
        try {
            MethodHandles.Lookup lookup = MethodHandles.lookup();
            A = lookup.findVarHandle(StoreBufferAcquireRelease.class, "a", int.class);
            B = lookup.findVarHandle(StoreBufferAcquireRelease.class, "b", int.class);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    int a;
    int b;

    @Actor
    public void stationA(II_Result r) {
        A.setRelease(this, 1);
        r.r1 = (int) B.getAcquire(this);
    }

    @Actor
    public void stationB(II_Result r) {
        B.setRelease(this, 1);
        r.r2 = (int) A.getAcquire(this);
    }
}
