package io.patterncatalyst.lowlat.offheap;

/**
 * The one place that switches Chronicle's usage analytics off.
 *
 * <p>Chronicle Queue and Chronicle Map each hold an {@code AnalyticsHolder} whose static
 * initializer, run when the first queue or map is built, asks Chronicle Core's
 * {@code AnalyticsFacade.isEnabled()}. That method reads the system property
 * {@code chronicle.analytics.disable} at that moment (through {@code Jvm.getBoolean}) and, unless
 * it is {@code true}, builds a Google Analytics 4 client that posts a {@code started} event with
 * the host's OS, JDK and memory facts. Setting the property before the first Chronicle class is
 * initialised is therefore enough, and it is read nowhere else.
 *
 * <p>Every class that touches Chronicle calls {@link #disable()} from a static initializer, so a
 * new entry point cannot forget it; the build adds the same {@code -D} to the surefire and exec
 * JVMs, and {@code scripts/validate.py} fails a source that imports Chronicle without either.
 */
final class ChronicleAnalytics {

    /** Chronicle Core's switch (see the class comment). */
    static final String PROPERTY = "chronicle.analytics.disable";

    private ChronicleAnalytics() {
    }

    /** Sets the switch; call before any Chronicle class is initialised. Idempotent. */
    static void disable() {
        System.setProperty(PROPERTY, "true");
    }
}
