package io.patterncatalyst.lowlat.ch02;

import java.nio.file.Path;
import java.util.Map;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.node.ObjectNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * Adds the optional {@code model} object to a report the measurement kit has written. The kit's
 * {@code Report} record has no {@code model} component, so the file is read back, the block is
 * added, and the file is written again. Everything the kit produced is kept untouched.
 */
final class ModelReport {

    private static final ObjectMapper MAPPER = JsonMapper.builder().build();

    private ModelReport() {
    }

    static void addModel(Path report, Map<String, ?> model) {
        JsonNode root = MAPPER.readTree(report.toFile());
        ((ObjectNode) root).set("model", MAPPER.valueToTree(model));
        MAPPER.writerWithDefaultPrettyPrinter().writeValue(report.toFile(), root);
    }
}
