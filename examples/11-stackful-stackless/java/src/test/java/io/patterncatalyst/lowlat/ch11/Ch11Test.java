package io.patterncatalyst.lowlat.ch11;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.OptionalLong;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

/** The deterministic parts of the Ch11 Java lane. Nothing is pinned, so no particular host is needed. */
class Ch11Test {

    @Test
    void argsParsePairsAndRejectBadInput() {
        Args args = new Args(List.of("--variant", "virtual-thread", "--tasks", "12"));
        assertEquals("virtual-thread", args.text("variant", ""));
        assertEquals(12, args.number("tasks", 0));
        assertEquals(7, args.number("rounds", 7));
        assertThrows(IllegalArgumentException.class, () -> new Args(List.of("tasks")));
        assertThrows(IllegalArgumentException.class, () -> new Args(List.of("--tasks")));
        assertThrows(IllegalArgumentException.class, () -> new Args(List.of("--tasks", "12abc")).number("tasks", 0));
    }

    @Test
    void cpuListsParseAndUnpinnedMeansMinusOne() {
        assertEquals(List.of(2, 5, 9), Placement.parseCpus("2,5,9"));
        assertThrows(IllegalArgumentException.class, () -> Placement.parseCpus("2,x"));
        assertThrows(IllegalArgumentException.class, () -> Placement.parseCpus("-1"));
        assertEquals(List.of(-1, -1), new Args(List.of()).cpus(2));
        assertTrue(Placement.placement(List.of(-1, -1)).isEmpty());
    }

    @Test
    void procFilesParse() {
        assertEquals(OptionalLong.of(1234), Procinfo.parse(List.of("Name:\tjava", "VmRSS:\t    1234 kB"), "VmRSS"));
        assertEquals(OptionalLong.empty(), Procinfo.parse(List.of("Name:\tjava"), "VmRSS"));
        assertTrue(Procinfo.snapshot(false).rssKib() > 0);
    }

    @Test
    void variantNamesAreTheTwoThreadKinds() {
        assertEquals(Run.Kind.PLATFORM, Run.Kind.parse("platform-thread"));
        assertEquals(Run.Kind.VIRTUAL, Run.Kind.parse("virtual-thread"));
        assertThrows(IllegalArgumentException.class, () -> Run.Kind.parse("thread"));
    }

    @ParameterizedTest
    @EnumSource(Run.Kind.class)
    void parkedTasksAllArriveAndWake(Run.Kind kind) throws Exception {
        Run run = ParkedRun.execute(kind, 60, 60, false, 0);
        assertEquals(60, run.samples().length);
        assertEquals(60L, run.counters().get("tasks_armed"));
        assertTrue(run.counters().get("rss_parked_kib") > 0);
    }

    @ParameterizedTest
    @EnumSource(Run.Kind.class)
    void pingPongServesEveryRoundTripAndKeepsThePayload(Run.Kind kind) throws Exception {
        Run run = PingPongRun.execute(kind, 2000, 100, 2, List.of(), 0, false);
        assertEquals(20, run.samples().length);
        assertEquals(2200L, run.counters().get("round_trips_served"));
        assertEquals(0L, run.counters().get("payload_mismatch"));
    }

    @Test
    void synchronizedDoesNotPinAndANativeFrameDoes() throws Exception {
        Run run = PinningRun.execute(5, 5);
        assertEquals(0L, run.counters().get("pinned_events_synchronized"), "JEP 491 (JDK 24): synchronized no longer pins");
        assertTrue(run.counters().get("pinned_events_native_frame") >= 1, "a native frame on the stack still pins");
    }
}
