package io.patterncatalyst.lowlat.ch12;

import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/** The service's exact counters, one {@code name value} line each; {@code POST /stats/reset} clears them after the warm-up. */
@Path("/stats")
public class StatsResource {

    @Inject
    ServiceStats stats;

    @GET
    @Produces(MediaType.TEXT_PLAIN)
    public String stats() {
        return stats.render();
    }

    @POST
    @Path("/reset")
    public void reset() {
        stats.reset();
    }
}
