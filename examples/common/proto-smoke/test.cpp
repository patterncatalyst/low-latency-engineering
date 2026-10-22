#include <gtest/gtest.h>

#include <string>

#include "lowlat/line/v1/parcel.pb.h"

TEST(ParcelEvent, RoundTrip) {
  lowlat::line::v1::ParcelEvent in;
  in.set_seq(7);
  in.set_intended_emit_ns(123456789);
  in.set_barcode("003412345678901234");  // leading zeros survive: a string, not a number
  in.mutable_dims()->set_length_mm(400);

  std::string wire;
  ASSERT_TRUE(in.SerializeToString(&wire));
  lowlat::line::v1::ParcelEvent out;
  ASSERT_TRUE(out.ParseFromString(wire));
  EXPECT_EQ(out.seq(), 7u);
  EXPECT_EQ(out.intended_emit_ns(), 123456789);
  EXPECT_EQ(out.barcode(), "003412345678901234");
  EXPECT_EQ(out.dims().length_mm(), 400u);
}
