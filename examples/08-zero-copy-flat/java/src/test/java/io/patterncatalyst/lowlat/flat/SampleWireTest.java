package io.patterncatalyst.lowlat.flat;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import io.patterncatalyst.lowlat.line.Decoder;
import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import org.junit.jupiter.api.Test;

/** The two wire formats of {@link SampleWire} carry the same parcels, and both lane rules agree. */
class SampleWireTest {

    @Test
    void protobufAndFlatDecodeToTheSameFields() throws Decoder.MalformedDatagramException {
        SampleWire wire = new SampleWire(256, 5);
        Decoder<ParcelEvent> protobuf = Decoder.protobuf();
        FlatDecoder flat = new FlatDecoder();
        ByteBuffer p = wire.protobuf();
        ByteBuffer f = wire.flat();
        for (int i = 0; i < wire.count(); i++) {
            p.clear().position(i * wire.protobufStride()).limit(i * wire.protobufStride() + wire.protobufLength(i));
            f.clear().position(i * wire.flatLength()).limit((i + 1) * wire.flatLength());
            ParcelEvent event = protobuf.decode(p);
            FlatView view = flat.decode(f);
            assertEquals(event.getSeq(), view.seq());
            assertEquals(event.getIntendedEmitNs(), view.intendedEmitNs());
            assertEquals(event.getActualEmitNs(), view.actualEmitNs());
            assertEquals(event.getEncoderTick(), view.encoderTick());
            assertEquals(event.getWeightG(), view.weightG());
            assertEquals(event.getDims().getLengthMm(), view.lengthMm());
            assertEquals(event.getDims().getWidthMm(), view.widthMm());
            assertEquals(event.getDims().getHeightMm(), view.heightMm());
            assertEquals(event.getScanConfidencePermille(), view.scanConfidencePermille());
            assertEquals(event.getBarcode(), view.barcode());
            assertEquals(Lanes.laneOf(event.getBarcode()), view.lane(), "lane from the bytes equals lane from the String");
        }
    }

    @Test
    void laneRejectsANonDigitBarcode() {
        FlatRecord bad = new FlatRecord(1, 1, 1, 1, 1, 1, 1, 1, 1, "00614141000000000x");
        ByteBuffer buffer = ByteBuffer.allocateDirect(ParcelLayout.SIZE);
        bad.writeFlat(MemorySegment.ofBuffer(buffer), 0);
        FlatView view = new FlatView().wrap(MemorySegment.ofBuffer(buffer), 0);
        assertThrows(IllegalArgumentException.class, view::lane);
    }
}
