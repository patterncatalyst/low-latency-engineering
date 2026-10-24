#include "cgroup_probe.hpp"

#include <gtest/gtest.h>

namespace lowlat::place {

TEST(CgroupProbe, ParsesQuotaAndPeriod) {
  const auto limited = parse_cpu_max("200000 100000\n");
  ASSERT_TRUE(limited.has_value());
  EXPECT_EQ(limited->quota_us, 200000);
  EXPECT_EQ(limited->period_us, 100000);
  const auto unlimited = parse_cpu_max("max 100000\n");
  ASSERT_TRUE(unlimited.has_value());
  EXPECT_FALSE(unlimited->quota_us.has_value());
}

TEST(CgroupProbe, RejectsMalformedText) { EXPECT_FALSE(parse_cpu_max("garbage")); }

// The host's own cgroup: the root cgroup has no cpu.max, so a missing file is an error value,
// not a crash; either outcome is a well-formed std::expected.
TEST(CgroupProbe, ReadsTheHostFileOrReportsWhyNot) {
  const auto host = read_cpu_max();
  if (host) {
    EXPECT_GT(host->period_us, 0);
  } else {
    EXPECT_FALSE(host.error().empty());
  }
}

}  // namespace lowlat::place
