package io.patterncatalyst.lowlat.ch12;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.TestProfile;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;

/**
 * Smoke test of the defect: {@code Thread.sleep(2)} on the event loop, with the 1 ms limit of the defect
 * configuration, makes Vert.x log a blocked-thread warning. At the 2 s default it would log none.
 */
@QuarkusTest
@TestProfile(DefectProfile.class)
class BlockingOnEventLoopTest {

    private static final Pattern WARNINGS = Pattern.compile("blocked_thread_warnings (\\d+)");

    private static long warnings() {
        Matcher m = WARNINGS.matcher(given().when().get("/stats").then().extract().asString());
        return m.find() ? Long.parseLong(m.group(1)) : 0;
    }

    @Test
    void aTwoMillisecondBlockOnTheLoopIsWarnedAbout() {
        given().post("/stats/reset").then().statusCode(204);
        // The count is for the server's whole life and Vert.x warns while it starts, so the test compares against a baseline.
        long baseline = warnings();
        given().when().get("/plan/blocking-on-event-loop/003400001234567890").then().statusCode(200).body(is("lane=5"));
        long warnings = baseline;
        // The checker samples every 10 ms; keep the loop blocked until a sample lands in a block.
        for (int i = 0; i < 400 && warnings == baseline; i++) {
            given().when().get("/plan/blocking-on-event-loop/003400001234567890").then().statusCode(200);
            warnings = warnings();
        }
        assertTrue(warnings > baseline, "no new blocked-thread warning after 400 blocked calls (baseline " + baseline + ")");
        String stats = given().when().get("/stats").then().extract().asString();
        assertTrue(stats.contains("event_loop_threads_seen"), stats);
        assertTrue(!stats.contains("event_loop_threads_seen 0\n"), stats);
    }
}
