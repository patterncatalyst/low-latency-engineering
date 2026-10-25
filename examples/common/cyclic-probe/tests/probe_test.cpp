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

TEST(Advance, AWakeExactlyOnTheNextDeadlineSkipsIt) {
  const auto next = advance(10ms, 11ms, 1ms);
  EXPECT_EQ(next.deadline, 12ms);
  EXPECT_EQ(next.skipped, 1U);
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
  EXPECT_EQ(outcome->samples, 30U);
  EXPECT_EQ(recorder.count(), 30);
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
