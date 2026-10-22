package io.patterncatalyst.lowlat.measure;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.Map;
import tools.jackson.databind.JsonNode;

/** One {@code lowlat-report/1} document; component names map to the schema's snake_case keys. */
public record Report(
        String schema,
        String example,
        String language,
        String variant,
        String unit,
        long count,
        long dropped,
        Percentiles percentiles,
        @JsonProperty("hdr_histogram") String hdrHistogram,
        BuildInfo build,
        JsonNode profile,
        @JsonInclude(JsonInclude.Include.NON_NULL) String notes,
        @JsonInclude(JsonInclude.Include.NON_NULL) Map<String, Object> model) {

    public static final String SCHEMA = "lowlat-report/1";
}
