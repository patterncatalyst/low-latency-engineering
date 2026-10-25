#include "placement.hpp"

#include <gtest/gtest.h>

#include <algorithm>

namespace lowlat::placement {
namespace {

using namespace std::chrono_literals;

TEST(CpuList, FormatsRangesAndSingles) {
  EXPECT_EQ(format_cpu_list({}), "");
  EXPECT_EQ(format_cpu_list({3}), "3");
  EXPECT_EQ(format_cpu_list({0, 1, 2, 3}), "0-3");
  EXPECT_EQ(format_cpu_list({0, 2, 3, 7}), "0,2-3,7");
}

TEST(Probe, ReportsACpuInsideTheAffinityMask) {
  const auto allowed = affinity_cpus();
  ASSERT_TRUE(allowed) << allowed.error();
  ASSERT_FALSE(allowed->empty());
  const auto cpu = current_cpu();
  ASSERT_TRUE(cpu) << cpu.error();
  EXPECT_TRUE(std::ranges::contains(*allowed, *cpu));
}

TEST(Probe, PinnedSpinStaysOnTheChosenCpuAndCountsSwitches) {
  const auto allowed = affinity_cpus();
  ASSERT_TRUE(allowed);
  const int target = allowed->front();
  const auto out = probe(target, 10ms);  // pinning to an allowed CPU needs no privilege
  ASSERT_TRUE(out) << out.error();
  EXPECT_EQ((*out)["schema"], "lowlat-placement-probe/1");
  EXPECT_EQ((*out)["affinity"], std::to_string(target));
  EXPECT_GE((*out)["context_switches"]["involuntary"].get<long>(), 0);
}

}  // namespace
}  // namespace lowlat::placement
