// Wiring proof: the target builds, links the measurement kit and runs under ctest.
#include <gtest/gtest.h>

#include "lowlat/jvmcosts/skeleton.hpp"
#include "lowlat/measure/recorder.hpp"

TEST(JvmCostsSkeleton, LinksTheKit) {
  EXPECT_EQ(lowlat::jvmcosts::name(), "jvm-costs");
  lowlat::measure::Recorder rec{"05-jvm-costs", "skeleton"};
  rec.record(1'000);
  EXPECT_EQ(rec.count(), 1);
}
