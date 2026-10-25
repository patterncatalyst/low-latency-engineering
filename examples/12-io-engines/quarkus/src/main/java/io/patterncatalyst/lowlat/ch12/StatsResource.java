package io.patterncatalyst.lowlat.ch12;

import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.jboss.logging.Logger;

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

    private static final Logger LOG = Logger.getLogger(StatsResource.class);

    /** Marks the start of the measured run in the log too, so a log count can be taken over the same interval. */
    static final String RUN_MARKER = "measured run begins";

    @POST
    @Path("/reset")
    public void reset() {
        stats.reset();
        LOG.info(RUN_MARKER);
    }
}
