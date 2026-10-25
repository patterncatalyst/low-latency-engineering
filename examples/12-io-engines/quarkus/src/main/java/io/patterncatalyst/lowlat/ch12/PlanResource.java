package io.patterncatalyst.lowlat.ch12;

import io.smallrye.common.annotation.Blocking;
import io.smallrye.common.annotation.NonBlocking;
import io.smallrye.common.annotation.RunOnVirtualThread;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.core.Vertx;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.jboss.resteasy.reactive.RestPath;

/**
 * The sort-plan lookup with a 2 ms downstream wait, served four ways. Same wait, same answer; what differs
 * is who holds the wait.
 *
 * <ul>
 *   <li>{@code event-loop}: the wait is a non-blocking Vert.x timer on the event loop; no thread is held.
 *   <li>{@code worker-pool}: the wait is {@code Thread.sleep} on one of the pool's fixed 8 worker threads.
 *   <li>{@code virtual-thread}: the wait is {@code Thread.sleep} on a virtual thread, which parks and frees
 *       its carrier.
 *   <li>{@code blocking-on-event-loop}: the defect. The same {@code Thread.sleep} on the event loop itself,
 *       which holds one of the few loop threads for the whole wait.
 * </ul>
 *
 * Adapted from the companion project quarkus-optimization (quarkus-demo-02-gc-monitoring GcMonitoringResource
 * for {@code @RunOnVirtualThread}; quarkus-demo-05-grpc for Mutiny {@code Uni}).
 */
@Path("/plan")
@Produces(MediaType.TEXT_PLAIN)
public class PlanResource {

    @Inject
    ServiceStats stats;

    @Inject
    Vertx vertx;

    @GET
    @Path("/event-loop/{sscc}")
    public Uni<String> eventLoop(@RestPath String sscc) {
        stats.begin();
        return Uni.createFrom().<String>emitter(emitter -> vertx.setTimer(SortPlan.WAIT_MS, id -> emitter.complete(SortPlan.answer(sscc))))
                .onTermination().invoke(stats::end);
    }

    @GET
    @Path("/worker-pool/{sscc}")
    @Blocking
    public String workerPool(@RestPath String sscc) throws InterruptedException {
        stats.begin();
        stats.workerBegin();
        try {
            Thread.sleep(SortPlan.WAIT_MS);
            return SortPlan.answer(sscc);
        } finally {
            stats.workerEnd();
            stats.end();
        }
    }

    @GET
    @Path("/virtual-thread/{sscc}")
    @RunOnVirtualThread
    public String virtualThread(@RestPath String sscc) throws InterruptedException {
        stats.begin();
        try {
            Thread.sleep(SortPlan.WAIT_MS);
            return SortPlan.answer(sscc);
        } finally {
            stats.end();
        }
    }

    /** The defect: a blocking call on the event loop. Never write this; it is here to be measured. */
    @GET
    @Path("/blocking-on-event-loop/{sscc}")
    @NonBlocking
    public String blockingOnEventLoop(@RestPath String sscc) throws InterruptedException {
        stats.begin();
        try {
            Thread.sleep(SortPlan.WAIT_MS);
            return SortPlan.answer(sscc);
        } finally {
            stats.end();
        }
    }
}
