// Wiring proof: the target builds, links the measurement kit and runs under ctest.
#include <gtest/gtest.h>

#include "lowlat/flat/skeleton.hpp"
#include "lowlat/measure/recorder.hpp"

TEST(FlatSkeleton, LinksTheKit) {
  EXPECT_EQ(lowlat::flat::name(), "zero-copy-flat");
  lowlat::measure::Recorder rec{"08-zero-copy-flat", "skeleton"};
  rec.record(1'000);
  EXPECT_EQ(rec.count(), 1);
}
