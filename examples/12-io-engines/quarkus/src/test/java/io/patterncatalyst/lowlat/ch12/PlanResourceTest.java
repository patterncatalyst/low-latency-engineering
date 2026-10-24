package io.patterncatalyst.lowlat.ch12;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;

import io.quarkus.test.junit.QuarkusTest;
import org.junit.jupiter.api.Test;

@QuarkusTest
class PlanResourceTest {

    @Test
    void planEndpointAnswersForAnSscc() {
        given().when().get("/plan/003400001234567890").then().statusCode(200).body(is("plan for 003400001234567890"));
    }
}
