#include "lowlat/cyclic/probe.hpp"

#include <gtest/gtest.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>

namespace lowlat::cyclic {
namespace {

using namespace std::chrono_literals;

TEST(Advance, StepsOneIntervalFromTheDeadlineNotFromNow) {
  // Woke 300 us late: the next deadline is still on the 1 ms grid.
  const auto next = advance(10ms, 10ms + 300us, 1ms);
  EXPECT_EQ(next.deadline, 11ms);
  EXPECT_EQ(next.skipped, 0U);
}

TEST(Advance, SkipsWholePeriodsAfterAStall) {
  // Woke 3.5 ms after the deadline: 11, 12 and 13 ms are past, so the next is 14 ms and three were skipped.
  const auto next = advance(10ms, 10ms + 3500us, 1ms);
  EXPECT_EQ(next.deadline, 14ms);
  EXPECT_EQ(next.skipped, 3U);
}

TEST(Advance, AWakeExactlyOnTheNextDeadlineDoesNotSkipIt) {
  // cyclictest skips only when now is strictly after the next deadline.
  const auto next = advance(10ms, 11ms, 1ms);
  EXPECT_EQ(next.deadline, 11ms);
  EXPECT_EQ(next.skipped, 0U);
}

TEST(Advance, ALandingOnAGridPointInsideAStallKeepsThatPoint) {
  const auto next = advance(10ms, 13ms, 1ms);  // 11 and 12 are past; 13 is now, not past
  EXPECT_EQ(next.deadline, 13ms);
  EXPECT_EQ(next.skipped, 2U);
}

TEST(MissedInWindow, CountsOnlyPeriodsInsideTheWindow) {
  EXPECT_EQ(missed_in_window(3, 11ms, 100ms, 1ms), 3U);
  EXPECT_EQ(missed_in_window(5, 11ms, 13ms, 1ms), 3U);  // 11, 12, 13 are inside; 14 and 15 are not
  EXPECT_EQ(missed_in_window(2, 20ms, 13ms, 1ms), 0U);
}

TEST(ToTimespec, SplitsSecondsAndNanoseconds) {
  const timespec ts = to_timespec(3s + 250ms);
  EXPECT_EQ(ts.tv_sec, 3);
  EXPECT_EQ(ts.tv_nsec, 250'000'000);
}

TEST(Validate, RejectsNonsense) {
  Config config;
  EXPECT_TRUE(validate(config));
  config.interval = 0ns;
  EXPECT_FALSE(validate(config));
  config = {};
  config.duration = 100us;
  EXPECT_FALSE(validate(config));
  config = {};
  config.fifo_priority = 100;
  EXPECT_FALSE(validate(config));
}

TEST(Run, RecordsOneSamplePerIntervalWithoutPrivilege) {
  measure::Recorder recorder{"16-cyclictest", "probe"};
  Config config;
  config.duration = 30ms;
  const auto outcome = run(config, recorder);
  ASSERT_TRUE(outcome) << outcome.error();
  EXPECT_EQ(outcome->samples + outcome->missed_periods, 30U);  // every period is a sample or a counted miss
  EXPECT_GE(outcome->samples, 1U);
  EXPECT_EQ(recorder.count(), static_cast<std::int64_t>(outcome->samples));
}

TEST(Run, EndsWithinTheRequestedDuration) {
  measure::Recorder recorder{"16-cyclictest", "probe"};
  Config config;
  config.duration = 50ms;
  const auto begun = now();
  const auto outcome = run(config, recorder);
  ASSERT_TRUE(outcome) << outcome.error();
  // The last deadline is at most start + duration; the generous slack covers a loaded CI runner's wake-up.
  EXPECT_LT(now() - begun, config.duration + 200ms);
}

TEST(Run, ReportsAnInvalidConfigAsAnError) {
  measure::Recorder recorder{"16-cyclictest", "probe"};
  Config config;
  config.interval = -1ns;
  EXPECT_FALSE(run(config, recorder));
}

TEST(RuntimeBlock, CarriesPlacementCountersAndEnvironment) {
  Config config;
  config.cpu = 2;
  const auto block = runtime_block(config, Outcome{.samples = 10, .missed_periods = 1}, "vm", "lab-ready-r05-rt/none");
  EXPECT_TRUE(block.contains("placement"));
  EXPECT_EQ(block["counters"]["samples"], 10);
  EXPECT_EQ(block["counters"]["missed_periods"], 1);
  EXPECT_EQ(block["environment"]["kind"], "vm");
}

TEST(Report, ValidatesAgainstTheKitWhenTheProfileIsSet) {
  setenv("LOWLAT_PROFILE", (std::filesystem::path{LOWLAT_FIXTURES_DIR} / "profile.json").c_str(), 1);
  measure::Recorder recorder{"16-cyclictest", "probe"};
  Config config;
  config.duration = 10ms;
  const auto outcome = run(config, recorder);
  ASSERT_TRUE(outcome) << outcome.error();
  const auto report = recorder.report("", std::nullopt, runtime_block(config, *outcome));
  EXPECT_EQ(report["schema"], "lowlat-report/1");
}

}  // namespace
}  // namespace lowlat::cyclic
