package io.patterncatalyst.lowlat.ch12;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.quarkus.test.junit.QuarkusTest;
import org.junit.jupiter.api.Test;

/** Smoke test of the worker-pool variant: a worker thread held the 2 ms wait. */
@QuarkusTest
class WorkerPoolTest {

    @Test
    void theWaitIsHeldByAWorkerThread() {
        given().post("/stats/reset").then().statusCode(204);
        given().when().get("/plan/worker-pool/003400001234567890").then().statusCode(200).body(is("lane=5"));
        String stats = given().when().get("/stats").then().statusCode(200).extract().asString();
        assertTrue(stats.contains("worker_threads_seen 1\n"), stats);
        assertTrue(stats.contains("worker_active_max 1\n"), stats);
        assertTrue(stats.contains("event_loop_threads_seen 0\n"), stats);
    }
}
