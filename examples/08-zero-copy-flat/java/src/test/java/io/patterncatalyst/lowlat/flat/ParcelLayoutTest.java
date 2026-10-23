package io.patterncatalyst.lowlat.flat;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.lang.foreign.MemoryLayout.PathElement;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;

/**
 * The Java layout is checked against the contract itself, not against constants typed twice: the
 * offsets the StructLayout derives must equal the {@code static_assert(offsetof(...))} lines of
 * {@code parcel_v1.hpp} and the rows of the table in the contract README.
 */
class ParcelLayoutTest {

    private static final Path CONTRACT = Path.of("../../../contracts/flat/parcel-v1");

    private static final Pattern OFFSETOF = Pattern.compile("static_assert\\(offsetof\\(Parcel, (\\w+)\\) == (\\d+)\\);");
    private static final Pattern K_SIZE = Pattern.compile("kSize = (\\d+);");
    // | 56 | 18 | char[18] | `barcode` | SSCC-18, ... |
    private static final Pattern TABLE_ROW = Pattern.compile("^\\| (\\d+) \\| (\\d+) \\| [^|]+ \\| `(\\w+)` \\|", Pattern.MULTILINE);

    @Test
    void sizeAndOffsetsMatchTheCppStaticAsserts() throws IOException {
        String header = Files.readString(CONTRACT.resolve("parcel_v1.hpp"));
        Matcher size = K_SIZE.matcher(header);
        assertTrue(size.find(), "kSize not found in parcel_v1.hpp");
        assertEquals(Integer.parseInt(size.group(1)), ParcelLayout.LAYOUT.byteSize());
        assertEquals(ParcelLayout.SIZE, ParcelLayout.LAYOUT.byteSize());

        Map<String, Long> cpp = new LinkedHashMap<>();
        Matcher offsets = OFFSETOF.matcher(header);
        while (offsets.find()) {
            cpp.put(offsets.group(1), Long.parseLong(offsets.group(2)));
        }
        assertEquals(13, cpp.size(), "one static_assert per field: " + cpp.keySet());
        cpp.forEach((field, offset) -> assertEquals(offset, ParcelLayout.offset(field), "offset of " + field));
    }

    @Test
    void offsetsAndSizesMatchTheReadmeTable() throws IOException {
        String readme = Files.readString(CONTRACT.resolve("README.md"));
        Matcher row = TABLE_ROW.matcher(readme);
        int rows = 0;
        while (row.find()) {
            String field = row.group(3);
            assertEquals(Long.parseLong(row.group(1)), ParcelLayout.offset(field), "offset of " + field);
            assertEquals(Long.parseLong(row.group(2)),
                    ParcelLayout.LAYOUT.select(PathElement.groupElement(field)).byteSize(), "size of " + field);
            rows++;
        }
        assertEquals(13, rows, "every field has a README row");
    }

    @Test
    void layoutHasNoImplicitPadding() {
        long named = ParcelLayout.LAYOUT.memberLayouts().stream().mapToLong(m -> m.byteSize()).sum();
        assertEquals(ParcelLayout.SIZE, named);
        assertFalse(ParcelLayout.LAYOUT.memberLayouts().stream().anyMatch(m -> m.name().isEmpty()), "every member is named");
    }
}
