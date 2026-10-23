package io.patterncatalyst.lowlat.lockfree;

import java.nio.file.Path;

/** Report file naming shared by the runs. */
final class Report {

    private Report() {
    }

    /** {@code <stem><suffix><ext>} beside {@code report}: the naming rule for the extra reports a run writes. */
    static Path sibling(Path report, String suffix) {
        String name = report.getFileName().toString();
        int dot = name.lastIndexOf('.');
        String stem = dot < 0 ? name : name.substring(0, dot);
        String extension = dot < 0 ? "" : name.substring(dot);
        return report.resolveSibling(stem + suffix + extension);
    }
}
