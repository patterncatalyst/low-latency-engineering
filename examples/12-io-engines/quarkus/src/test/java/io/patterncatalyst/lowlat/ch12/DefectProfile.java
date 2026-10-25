package io.patterncatalyst.lowlat.ch12;

import io.quarkus.test.junit.QuarkusTestProfile;

/** The {@code defect} configuration profile of application.properties ({@code %defect.*}): a 1 ms limit and a 10 ms checker period. */
public class DefectProfile implements QuarkusTestProfile {

    @Override
    public String getConfigProfile() {
        return "defect";
    }
}
