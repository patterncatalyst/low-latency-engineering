package io.patterncatalyst.lowlat.measure;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;

/** How the measured program was run. {@code gilEnabled} is always null for Java. */
public record BuildInfo(
        String compiler,
        @JsonInclude(JsonInclude.Include.NON_NULL) String flags,
        @JsonProperty("gil_enabled") Boolean gilEnabled) {

    /** The running JVM: {@code Runtime.version()} plus {@code java.vm.name}. */
    public static BuildInfo current() {
        return new BuildInfo(
                "OpenJDK " + Runtime.version() + " (" + System.getProperty("java.vm.name") + ")",
                null,
                null);
    }
}
