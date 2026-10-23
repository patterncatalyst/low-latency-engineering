package io.patterncatalyst.lowlat.measure;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * The reported percentiles, integer nanoseconds. There is no
 * mean component: the schema forbids any other key.
 */
public record Percentiles(long p50, long p90, long p99, @JsonProperty("p99_9") long p999, long max) {
}
