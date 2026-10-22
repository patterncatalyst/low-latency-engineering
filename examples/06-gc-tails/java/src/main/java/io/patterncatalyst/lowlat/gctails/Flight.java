package io.patterncatalyst.lowlat.gctails;

import java.io.IOException;
import java.nio.file.Path;
import java.text.ParseException;
import jdk.jfr.Configuration;
import jdk.jfr.Recording;

/**
 * A flight recording that covers the measured run only.
 *
 * <p>Starting JFR with {@code -XX:StartFlightRecording} records from JVM start, so the pauses of
 * the manifest build, the warm-up and the forced collection that measures the live set would be
 * counted with the run's. This starts the recording in-process, after those, with the same
 * {@code default} settings, and writes it to the file when the run ends.
 */
final class Flight {

    /** The measured run: what happens between the start and the end of the recording. */
    @FunctionalInterface
    interface Run<T> {
        T call() throws IOException;
    }

    private Flight() {
    }

    /** Runs {@code run} inside a recording that is written to {@code file} when it returns or throws. */
    static <T> T during(Path file, Run<T> run) throws IOException {
        Recording recording;
        try {
            recording = new Recording(Configuration.getConfiguration("default"));
        } catch (ParseException e) {
            throw new IOException("cannot read the default JFR settings", e);
        }
        try (recording) {
            recording.setDestination(file);
            recording.start();
            try {
                return run.call();
            } finally {
                recording.stop(); // writes the destination file
            }
        }
    }
}
