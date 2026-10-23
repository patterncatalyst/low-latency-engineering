package io.patterncatalyst.lowlat.line;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/** Java reads the bytes the C++ header wrote: contracts/flat/parcel-v1/golden-seedN.bin. */
class FlatParcelGoldenTest {

    private static Path goldenDir() {
        Path examples = Path.of(System.getProperty("lowlat.examples.dir", "../../../..")).toAbsolutePath().normalize();
        return examples.resolveSibling("contracts").resolve("flat").resolve("parcel-v1");
    }

    @Test
    void layoutMatchesTheContract() {
        assertEquals(80, FlatParcel.LAYOUT.byteSize());
        assertEquals(80, FlatParcel.SIZE);
    }

    @ParameterizedTest
    @ValueSource(longs = {1, 42, 2026})
    void goldenBytesDecodeToTheirJson(long seed) throws IOException {
        byte[] bytes = Files.readAllBytes(goldenDir().resolve("golden-seed" + seed + ".bin"));
        JsonNode doc = JsonMapper.builder().build().readTree(goldenDir().resolve("golden-seed" + seed + ".json"));
        int count = doc.get("count").asInt();
        assertEquals(count * FlatParcel.SIZE, bytes.length);
        MemorySegment segment = MemorySegment.ofArray(bytes);
        FlatParcel view = new FlatParcel();
        for (int i = 0; i < count; i++) {
            JsonNode expect = doc.get("records").get(i);
            view.wrap(segment, (long) i * FlatParcel.SIZE);
            String where = "seed " + seed + " record " + i;
            assertEquals(expect.get("schema_id").asInt(), view.schemaId(), where);
            assertEquals(expect.get("version").asInt(), view.version(), where);
            assertEquals(expect.get("weight_g").asLong(), view.weightG(), where);
            assertEquals(expect.get("seq").asString(), Long.toUnsignedString(view.seq()), where);
            assertEquals(expect.get("intended_emit_ns").asString(), Long.toString(view.intendedEmitNs()), where);
            assertEquals(expect.get("actual_emit_ns").asString(), Long.toString(view.actualEmitNs()), where);
            assertEquals(expect.get("encoder_tick").asString(), Long.toUnsignedString(view.encoderTick()), where);
            assertEquals(expect.get("length_mm").asLong(), view.lengthMm(), where);
            assertEquals(expect.get("width_mm").asLong(), view.widthMm(), where);
            assertEquals(expect.get("height_mm").asLong(), view.heightMm(), where);
            assertEquals(expect.get("scan_confidence_permille").asLong(), view.scanConfidencePermille(), where);
            assertEquals(expect.get("barcode").asString(), view.barcode(), where);
        }
    }

    @Test
    void writerProducesTheSameBytesAsTheHeaderForTheExtremesRecord() throws IOException {
        byte[] golden = Files.readAllBytes(goldenDir().resolve("golden-seed1.bin"));
        // Record 0 is the extremes record, except its u32 fields (all 0xFFFFFFFF), which write() leaves 0.
        byte[] mine = new byte[FlatParcel.SIZE];
        FlatParcel.write(MemorySegment.ofArray(mine), 0, -1L, Long.MIN_VALUE, Long.MAX_VALUE, "0".repeat(18));
        for (int at : new int[] {0, 1, 2, 3, 8, 9, 15, 16, 23, 24, 31, 56, 73, 74, 79}) {
            assertEquals(golden[at], mine[at], "byte " + at);
        }
    }

    @Test
    void decoderRejectsWrongSizeSchemaAndVersion() throws Exception {
        FlatParcel.FlatDecoder decoder = new FlatParcel.FlatDecoder();
        ByteBuffer good = ByteBuffer.allocateDirect(FlatParcel.SIZE);
        FlatParcel.write(MemorySegment.ofBuffer(good), 0, 7, 1, 2, "006141410000000008");
        assertEquals(7, decoder.seq(decoder.decode(good)));

        assertThrows(Decoder.MalformedDatagramException.class, () -> decoder.decode(good.duplicate().limit(79)));
        ByteBuffer wrongSchema = ByteBuffer.allocateDirect(FlatParcel.SIZE);
        FlatParcel.write(MemorySegment.ofBuffer(wrongSchema), 0, 7, 1, 2, "006141410000000008");
        wrongSchema.put(0, (byte) 2);
        assertThrows(Decoder.MalformedDatagramException.class, () -> decoder.decode(wrongSchema));
        ByteBuffer wrongVersion = ByteBuffer.allocateDirect(FlatParcel.SIZE);
        FlatParcel.write(MemorySegment.ofBuffer(wrongVersion), 0, 7, 1, 2, "006141410000000008");
        wrongVersion.put(2, (byte) 2);
        assertThrows(Decoder.MalformedDatagramException.class, () -> decoder.decode(wrongVersion));
    }

    @Test
    void aLaterLargerVersionIsUnsupportedNotABadSize() {
        FlatParcel.FlatDecoder decoder = new FlatParcel.FlatDecoder();
        ByteBuffer v2 = ByteBuffer.allocateDirect(96);
        FlatParcel.write(MemorySegment.ofBuffer(v2), 0, 7, 1, 2, "006141410000000008");
        v2.put(2, (byte) 2);
        var e = assertThrows(Decoder.MalformedDatagramException.class, () -> decoder.decode(v2));
        assertTrue(e.getMessage().contains("unsupported parcel-v1 version 2"), e.getMessage());
        ByteBuffer shortHeader = ByteBuffer.allocateDirect(FlatParcel.SIZE);
        var h = assertThrows(Decoder.MalformedDatagramException.class,
                () -> decoder.decode(shortHeader.duplicate().limit(3)));
        assertTrue(h.getMessage().contains("header"), h.getMessage());
    }
}
