package io.patterncatalyst.lowlat.ch12;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.quarkus.test.junit.QuarkusTest;
import org.junit.jupiter.api.Test;

/** Smoke test of the virtual-thread variant: the wait ran on a virtual thread, whose carriers are counted. */
@QuarkusTest
class VirtualThreadTest {

    @Test
    void theWaitIsHeldByAVirtualThread() {
        given().post("/stats/reset").then().statusCode(204);
        given().when().get("/plan/virtual-thread/003400001234567890").then().statusCode(200).body(is("lane=5"));
        String stats = given().when().get("/stats").then().statusCode(200).extract().asString();
        assertFalse(stats.contains("carrier_threads 0\n"), stats); // the scheduler's pool has at least one carrier
        assertTrue(stats.contains("worker_threads_seen 0\n"), stats);
    }
}
