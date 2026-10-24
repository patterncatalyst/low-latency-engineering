package io.patterncatalyst.lowlat.ch12;

import io.quarkus.test.junit.QuarkusTestProfile;
import java.util.Map;

/** The defect configuration of application.properties (%defect), applied to a test: a 1 ms limit and a 10 ms checker period. */
public class DefectProfile implements QuarkusTestProfile {

    @Override
    public Map<String, String> getConfigOverrides() {
        return Map.of("quarkus.vertx.max-event-loop-execute-time", "1ms", "quarkus.vertx.warning-exception-time", "10ms");
    }
}
