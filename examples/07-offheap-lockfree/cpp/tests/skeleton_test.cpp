// Wiring proof: the target builds, links the measurement kit and runs under ctest.
#include <gtest/gtest.h>

#include "lowlat/offheap/skeleton.hpp"
#include "lowlat/measure/recorder.hpp"

TEST(OffheapSkeleton, LinksTheKit) {
  EXPECT_EQ(lowlat::offheap::name(), "offheap-lockfree");
  lowlat::measure::Recorder rec{"07-offheap-lockfree", "skeleton"};
  rec.record(1'000);
  EXPECT_EQ(rec.count(), 1);
}
