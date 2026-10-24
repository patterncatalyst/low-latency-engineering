package io.patterncatalyst.lowlat.ch12;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;

/** Wiring skeleton: the sort-plan lookup for a parcel, answered as plain text. */
@Path("/plan")
public class PlanResource {

    @GET
    @Path("/{sscc}")
    public String plan(@PathParam("sscc") String sscc) {
        return "plan for " + sscc;
    }
}
