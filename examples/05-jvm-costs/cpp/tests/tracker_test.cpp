// The tracker's rules, and the same rules the Java Tracker applies.
#include <gtest/gtest.h>

#include <string>

#include "lowlat/jvmcosts/tracker.hpp"

namespace {

namespace jvmcosts = lowlat::jvmcosts;
namespace v1 = lowlat::line::v1;

v1::ParcelEvent parcel(std::uint64_t seq, std::uint32_t weight_g, std::uint32_t longest_mm, std::uint32_t confidence) {
  v1::ParcelEvent ev;
  ev.set_seq(seq);
  ev.set_encoder_tick(seq * 2);
  ev.set_barcode(std::to_string(100'000'000'000'000'000ULL + seq));  // 18 digits
  ev.set_weight_g(weight_g);
  ev.mutable_dims()->set_length_mm(longest_mm);
  ev.mutable_dims()->set_width_mm(200);
  ev.mutable_dims()->set_height_mm(100);
  ev.set_scan_confidence_permille(confidence);
  return ev;
}

TEST(Decide, LaneFollowsConfidenceSizeAndWeight) {
  EXPECT_EQ(jvmcosts::decide(parcel(0, 2500, 400, 800)).lane, jvmcosts::kExceptionLane);  // unreadable scan
  EXPECT_EQ(jvmcosts::decide(parcel(0, 2500, 1200, 990)).lane, jvmcosts::kOversizeLane);  // longer than 1 m
  EXPECT_EQ(jvmcosts::decide(parcel(0, 31'000, 400, 990)).lane, jvmcosts::kOversizeLane);  // over 30 kg
  EXPECT_EQ(jvmcosts::decide(parcel(0, 500, 400, 990)).lane, 1U);                         // under 1 kg
  EXPECT_EQ(jvmcosts::decide(parcel(0, 2500, 400, 990)).lane, 3U);                        // 2 kg class
  EXPECT_EQ(jvmcosts::decide(parcel(0, 20'000, 400, 990)).lane, jvmcosts::kSortLanes);    // heaviest sort lane
}

TEST(Decide, DeadlineIsTheScanTickPlusTheBeltDistance) {
  EXPECT_EQ(jvmcosts::decide(parcel(5, 2500, 400, 990)).deadline_tick, 10 + jvmcosts::kDivertTicks);
}

TEST(Tracker, ParcelsLeaveTheTableAtTheirDeadline) {
  jvmcosts::Tracker tracker;
  // 2 ticks apart: a parcel is in flight for kDivertTicks / 2 = 600 successors.
  for (std::uint64_t seq = 0; seq < 2000; ++seq) tracker.on_parcel(parcel(seq, 2500, 400, 990));
  EXPECT_EQ(tracker.in_flight_count(), 600U);
  EXPECT_TRUE(tracker.is_in_flight(parcel(1999, 0, 0, 0).barcode()));
  EXPECT_FALSE(tracker.is_in_flight(parcel(0, 0, 0, 0).barcode()));
}

}  // namespace
