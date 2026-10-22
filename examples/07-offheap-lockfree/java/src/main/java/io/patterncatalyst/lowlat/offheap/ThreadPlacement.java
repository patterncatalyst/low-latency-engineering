package io.patterncatalyst.lowlat.offheap;

/**
 * Where the decide thread runs. The hand-off structures start their consumer through
 * {@link #wrap}, so a placement that pins the thread to a CPU (the affinity variants of the VM
 * part) wraps the thread body in a lock held for its lifetime and nothing else changes.
 *
 * <p>The host part has one placement: {@link #UNPINNED}, the scheduler's choice. Pinning proves
 * nothing without an isolated CPU to pin to, and isolating a CPU is a change to the machine; it
 * happens in the lab VM.
 */
@FunctionalInterface
public interface ThreadPlacement {

    /** The scheduler decides. */
    ThreadPlacement UNPINNED = body -> body;

    /** The placement for {@code name}, as given to {@code --placement}. */
    static ThreadPlacement named(String name) {
        return switch (name) {
            case "unpinned" -> UNPINNED;
            default -> throw new IllegalArgumentException(
                    "--placement: unpinned (the pinned-isolated placement belongs to the VM part)");
        };
    }

    /** The body the decide thread runs: {@code body} itself, or {@code body} inside whatever the placement holds. */
    Runnable wrap(Runnable body);
}
