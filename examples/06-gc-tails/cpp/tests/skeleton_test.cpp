// Wiring proof: the target builds, links the measurement kit and runs under ctest.
#include <gtest/gtest.h>

#include "lowlat/gctails/skeleton.hpp"
#include "lowlat/measure/recorder.hpp"

TEST(GcTailsSkeleton, LinksTheKit) {
  EXPECT_EQ(lowlat::gctails::name(), "gc-tails");
  lowlat::measure::Recorder rec{"06-gc-tails", "skeleton"};
  rec.record(1'000);
  EXPECT_EQ(rec.count(), 1);
}
