package io.patterncatalyst.lowlat.line.v1;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.google.protobuf.InvalidProtocolBufferException;
import org.junit.jupiter.api.Test;

class ParcelEventRoundTripTest {

  @Test
  void roundTrip() throws InvalidProtocolBufferException {
    ParcelEvent in = ParcelEvent.newBuilder()
        .setSeq(7)
        .setIntendedEmitNs(123_456_789L)
        .setBarcode("003412345678901234") // a string: leading zeros survive
        .setDims(Dimensions.newBuilder().setLengthMm(400))
        .build();

    byte[] wire = in.toByteArray();
    ParcelEvent out = ParcelEvent.parseFrom(wire);

    assertEquals(in, out);
    assertEquals("003412345678901234", out.getBarcode());
    assertEquals(400, out.getDims().getLengthMm());
  }
}
