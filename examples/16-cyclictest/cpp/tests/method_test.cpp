#include "method.hpp"

#include <gtest/gtest.h>

namespace lowlat::ch16 {
namespace {

using namespace std::chrono_literals;

TEST(Method, MatchesTheCyclictestMethodLane) {
  const auto config = method(300s);
  EXPECT_EQ(config.fifo_priority, 95);
  EXPECT_EQ(config.interval, 1ms);
  EXPECT_TRUE(config.lock_memory);
  EXPECT_TRUE(cyclic::validate(config));
  // 300 s at 1 ms is the lane's sample count the converter checks against.
  EXPECT_EQ(config.duration / config.interval, 300'000);
}

TEST(Method, RunsWithoutPrivilegeWhenFifoAndPinAreDropped) {
  auto config = method(1s);
  config.duration = 20ms;
  config.cpu = -1;
  config.fifo_priority = 0;
  config.lock_memory = false;
  measure::Recorder recorder{"16-cyclictest", "probe"};
  const auto outcome = cyclic::run(config, recorder);
  ASSERT_TRUE(outcome) << outcome.error();
  EXPECT_EQ(outcome->samples, 20U);
}

}  // namespace
}  // namespace lowlat::ch16
