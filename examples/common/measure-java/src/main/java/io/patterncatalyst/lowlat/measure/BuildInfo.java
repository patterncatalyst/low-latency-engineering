package io.patterncatalyst.lowlat.measure;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import java.lang.management.ManagementFactory;
import java.util.List;

/** How the measured program was run. {@code gilEnabled} is always null for Java. */
public record BuildInfo(
        String compiler,
        @JsonInclude(JsonInclude.Include.NON_NULL) String flags,
        @JsonProperty("gil_enabled") Boolean gilEnabled) {

    /**
     * The running JVM: {@code Runtime.version()} plus {@code java.vm.name}, with the JVM input
     * arguments (what was passed on the command line or in {@code JAVA_TOOL_OPTIONS}) joined by
     * single spaces as {@code flags}; null when there are none.
     */
    public static BuildInfo current() {
        List<String> args = ManagementFactory.getRuntimeMXBean().getInputArguments();
        return new BuildInfo(
                "OpenJDK " + Runtime.version() + " (" + System.getProperty("java.vm.name") + ")",
                args.isEmpty() ? null : String.join(" ", args),
                null);
    }
}
