package io.patterncatalyst.lowlat.eliminating;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;

import java.io.IOException;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/** SSCC packing, against the barcodes of the contracts/flat/parcel-v1 golden files. */
class SsccTest {

    private static final Path CONTRACT = Path.of("../../../contracts/flat/parcel-v1");

    @Test
    void packsAndFormatsRoundTrip() {
        assertEquals(42L, Sscc.pack("000000000000000042"));
        assertEquals(999_999_999_999_999_999L, Sscc.pack("999999999999999999"));
        assertEquals("000000000000000042", Sscc.format(42));
        assertEquals("999999999999999999", Sscc.format(999_999_999_999_999_999L));
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "1234567", "12345678901234567", "1234567890123456789", "12345678901234567x",
            "+23456789012345678", "-23456789012345678", " 23456789012345678"})
    void rejectsAnythingButEighteenDigits(String bad) {
        assertEquals(Sscc.INVALID, Sscc.pack(bad));
    }

    @Test
    void goldenBarcodesPackToTheirDigits() throws IOException {
        JsonMapper mapper = JsonMapper.builder().build();
        int checked = 0;
        for (String seed : new String[] {"1", "42", "2026"}) {
            JsonNode golden = mapper.readTree(CONTRACT.resolve("golden-seed" + seed + ".json").toFile());
            for (JsonNode record : golden.get("records")) {
                String barcode = record.get("barcode").asString();
                long packed = Sscc.pack(barcode);
                assertNotEquals(Sscc.INVALID, packed, barcode);
                assertEquals(Long.parseLong(barcode), packed, barcode);
                assertEquals(barcode, Sscc.format(packed));
                checked++;
            }
        }
        assertEquals(24, checked); // 3 seeds x 8 records
    }

    @Test
    void seededKeysAreDistinctEighteenDigits() {
        Keys keys = Keys.make(5_000, 7);
        assertEquals(5_000, java.util.stream.IntStream.range(0, 5_000)
                .mapToLong(keys::packed).distinct().count());
        for (int i = 0; i < keys.size(); i++) {
            assertEquals(Sscc.DIGITS, keys.text(i).length());
            assertEquals(keys.packed(i), Sscc.pack(keys.text(i)));
        }
    }

    @Test
    void keyArithmeticMatchesBigInteger() {
        java.math.BigInteger stride = java.math.BigInteger.valueOf(1_442_695_040_888_963_407L);
        java.math.BigInteger space = java.math.BigInteger.valueOf(Keys.SSCC_SPACE);
        for (long seed : new long[] {0, 1, 2026, 7}) {
            for (long i : new long[] {0, 1, 2, 999_999, 1_000_003, 123_456_789}) {
                long expected = java.math.BigInteger.valueOf(i + seed * 0x9E3779B1L).multiply(stride).mod(space).longValueExact();
                assertEquals(expected, Keys.ssccOf(seed, i), "seed " + seed + " key " + i);
            }
        }
    }
}
