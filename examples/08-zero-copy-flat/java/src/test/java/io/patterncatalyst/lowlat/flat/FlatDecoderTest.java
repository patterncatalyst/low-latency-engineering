package io.patterncatalyst.lowlat.flat;

import static java.lang.foreign.ValueLayout.JAVA_SHORT_UNALIGNED;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.management.ThreadMXBean;
import io.patterncatalyst.lowlat.line.Decoder;
import io.patterncatalyst.lowlat.line.Decoder.MalformedDatagramException;
import java.io.IOException;
import java.lang.foreign.MemorySegment;
import java.lang.management.ManagementFactory;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/** {@link FlatDecoder} reads the golden bytes the C++ header wrote and rejects what it must. */
class FlatDecoderTest {

    private static final Path CONTRACT = Path.of("../../../contracts/flat/parcel-v1");

    private static ByteBuffer direct(byte[] bytes) {
        return ByteBuffer.allocateDirect(bytes.length).put(bytes).flip();
    }

    @ParameterizedTest
    @ValueSource(longs = {1, 42, 2026})
    void goldenBytesDecodeToTheirJson(long seed) throws IOException, MalformedDatagramException {
        byte[] bytes = Files.readAllBytes(CONTRACT.resolve("golden-seed" + seed + ".bin"));
        JsonNode doc = JsonMapper.builder().build().readTree(CONTRACT.resolve("golden-seed" + seed + ".json"));
        int count = doc.get("count").asInt();
        assertEquals(count * ParcelLayout.SIZE, bytes.length);
        ByteBuffer buffer = direct(bytes);
        FlatDecoder decoder = new FlatDecoder();
        for (int i = 0; i < count; i++) {
            int at = i * ParcelLayout.SIZE;
            buffer.clear().position(at).limit(at + ParcelLayout.SIZE);
            FlatView view = decoder.decode(buffer);
            JsonNode expect = doc.get("records").get(i);
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
    void theViewIsReusedAndSeqFeedsTheGapTracker() throws MalformedDatagramException {
        SampleWire wire = new SampleWire(4, 7);
        FlatDecoder decoder = new FlatDecoder();
        ByteBuffer buffer = wire.flat();
        buffer.clear().position(ParcelLayout.SIZE).limit(2 * ParcelLayout.SIZE);
        FlatView first = decoder.decode(buffer);
        long seq = decoder.seq(first);
        buffer.clear().position(3 * ParcelLayout.SIZE).limit(4 * ParcelLayout.SIZE);
        FlatView second = decoder.decode(buffer);
        assertSame(first, second, "one view serves every datagram");
        assertEquals(1, seq);
        assertEquals(3, decoder.seq(second));
    }

    @Test
    void rejectsShortWrongSchemaUnsupportedVersionAndWrongSize() {
        FlatDecoder decoder = new FlatDecoder();
        ByteBuffer buffer = ByteBuffer.allocateDirect(2 * ParcelLayout.SIZE);
        MemorySegment segment = MemorySegment.ofBuffer(buffer);
        new FlatRecord(7, 1, 2, 3, 4, 5, 6, 7, 8, "006141410000000008").writeFlat(segment, 0);

        buffer.clear().limit(3);
        assertThrows(MalformedDatagramException.class, () -> decoder.decode(buffer), "fewer than 4 header bytes");

        buffer.clear().limit(ParcelLayout.SIZE - 1);
        assertThrows(MalformedDatagramException.class, () -> decoder.decode(buffer), "79 bytes");
        buffer.clear().limit(ParcelLayout.SIZE + 1);
        assertThrows(MalformedDatagramException.class, () -> decoder.decode(buffer), "81 bytes");

        buffer.clear().limit(ParcelLayout.SIZE);
        segment.set(JAVA_SHORT_UNALIGNED, 0, (short) 2);
        MalformedDatagramException schema = assertThrows(MalformedDatagramException.class, () -> decoder.decode(buffer));
        assertTrue(schema.getMessage().contains("schema_id 2"), schema.getMessage());

        segment.set(JAVA_SHORT_UNALIGNED, 0, (short) 1);
        segment.set(JAVA_SHORT_UNALIGNED, 2, (short) 2);
        // A v2 record is larger: the version is checked before the size, so this is "unsupported", not "wrong size".
        buffer.clear().limit(2 * ParcelLayout.SIZE);
        MalformedDatagramException version = assertThrows(MalformedDatagramException.class, () -> decoder.decode(buffer));
        assertTrue(version.getMessage().contains("unsupported parcel-v1 version 2"), version.getMessage());
    }

    @Test
    void decodingAllocatesNothingPerParcel() throws MalformedDatagramException {
        SampleWire wire = new SampleWire(1024, 11);
        FlatDecoder decoder = new FlatDecoder();
        ByteBuffer buffer = wire.flat();
        long checksum = 0;
        for (int round = 0; round < 300; round++) { // warm up past the interpreter and C1
            checksum += pass(decoder, buffer);
        }
        ThreadMXBean threads = (ThreadMXBean) ManagementFactory.getThreadMXBean();
        long thread = Thread.currentThread().threadId();
        long before = threads.getThreadAllocatedBytes(thread);
        int rounds = 200;
        for (int round = 0; round < rounds; round++) {
            checksum += pass(decoder, buffer);
        }
        long allocated = threads.getThreadAllocatedBytes(thread) - before;
        long parcels = (long) rounds * wire.count();
        assertTrue(checksum != 0);
        // Not exactly zero: the measuring call itself and a TLAB refill are not free. 1 byte per parcel is the contract.
        assertTrue(allocated <= parcels, allocated + " bytes for " + parcels + " parcels");
    }

    private static long pass(Decoder<FlatView> decoder, ByteBuffer buffer) throws MalformedDatagramException {
        long sum = 0;
        for (int i = 0; i < 1024; i++) {
            int at = i * ParcelLayout.SIZE;
            buffer.clear().position(at).limit(at + ParcelLayout.SIZE);
            FlatView view = decoder.decode(buffer);
            sum += view.seq() + view.weightG() + view.lane();
        }
        return sum;
    }
}
