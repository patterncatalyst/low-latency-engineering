package io.patterncatalyst.lowlat.ch12;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.is;

import io.quarkus.test.junit.QuarkusTest;
import org.junit.jupiter.api.Test;

/** Smoke test of the event-loop variant: the answer is right and a Vert.x event-loop thread served it. */
@QuarkusTest
class EventLoopTest {

    @Test
    void theWaitIsATimerOnTheEventLoop() {
        given().post("/stats/reset").then().statusCode(204);
        given().when().get("/plan/event-loop/003400001234567890").then().statusCode(200).body(is("lane=5"));
        String stats = given().when().get("/stats").then().statusCode(200).extract().asString();
        org.junit.jupiter.api.Assertions.assertTrue(stats.contains("service_requests 1\n"), stats);
        org.junit.jupiter.api.Assertions.assertFalse(stats.contains("event_loop_threads_seen 0\n"), stats);
        org.junit.jupiter.api.Assertions.assertTrue(stats.contains("worker_threads_seen 0\n"), stats);
        given().when().get("/stats").then().body(containsString("blocked_thread_warnings"));
    }
}
