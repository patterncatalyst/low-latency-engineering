package io.patterncatalyst.lowlat.ch12;

import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import java.util.logging.Handler;
import java.util.logging.Level;
import java.util.logging.LogRecord;
import java.util.logging.Logger;

/**
 * Counts the warnings Vert.x's blocked-thread checker logs, as they are logged: the same records that reach
 * the console, counted in process, so the number in the report is exact and verify.sh cross-checks it
 * against the log file.
 */
@ApplicationScoped
public class BlockedThreadWarnings {

    static final String LOGGER = "io.vertx.core.impl.BlockedThreadChecker";

    @Inject
    ServiceStats stats;

    private final Handler handler = new Handler() {
        @Override
        public void publish(LogRecord record) {
            if (record.getLevel().intValue() >= Level.WARNING.intValue()) {
                stats.blockedThreadWarning();
            }
        }

        @Override
        public void flush() {
            // nothing is buffered
        }

        @Override
        public void close() {
            // nothing is held
        }
    };

    void onStart(@Observes StartupEvent event) {
        Logger.getLogger(LOGGER).addHandler(handler);
    }
}
