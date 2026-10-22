// Smoke tests for the experiment pieces. The measurement is verify.sh's job.
#include <gtest/gtest.h>

#include <string_view>
#include <vector>

#include "lowlat/co/experiment.hpp"

namespace co = lowlat::co;

TEST(Args, Defaults) {
  const auto c = co::parse_args({});
  EXPECT_EQ(c.stall_ms, 200);
  EXPECT_EQ(c.stall_seq, 5000u);
  EXPECT_EQ(c.expect, 10'000u);
}

TEST(Args, ControlRun) {
  const std::vector<std::string_view> a{"--stall-ms", "0", "--suffix", "-control"};
  const auto c = co::parse_args(a);
  EXPECT_EQ(c.stall_ms, 0);
  EXPECT_EQ(c.suffix, "-control");
}

TEST(Args, Rejects) {
  const std::vector<std::string_view> unknown{"--nope", "1"};
  EXPECT_THROW((void)co::parse_args(unknown), std::invalid_argument);
  const std::vector<std::string_view> missing{"--stall-ms"};
  EXPECT_THROW((void)co::parse_args(missing), std::invalid_argument);
}

// The correction is the point: the same closed-loop stall, recorded two ways.
TEST(ClosedLoop, CorrectionBackfillsTheStall) {
  co::Config cfg;
  cfg.stall_ms = 50;
  cfg.stall_seq = 100;
  co::Recorders rec{""};
  co::run_closed_loop(cfg, 300, rec);
  EXPECT_EQ(rec.closed_loop_naive.count(), 300);
  EXPECT_GT(rec.closed_loop_corrected.count(), 300 + 40);  // ~49 back-filled samples
}

TEST(ClockProbe, RecordsEveryCall) {
  co::ClockProbe p;
  co::run_clock_probe(1000, p);
  EXPECT_EQ(p.line_monotonic_ns.count(), 1000);
  EXPECT_EQ(p.steady_clock.count(), 1000);
}
