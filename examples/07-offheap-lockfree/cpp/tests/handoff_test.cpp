// Handoff: the decide thread's failure must surface from drain(), not terminate the process or
// leave drain() waiting for records that will never be handled.
#include <gtest/gtest.h>

#include <chrono>
#include <cstdint>
#include <stdexcept>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/offheap/handoff.hpp"

namespace {

namespace line = lowlat::line;
using lowlat::offheap::Handoff;
using lowlat::offheap::Wait;
using namespace std::chrono_literals;

line::v1::ParcelEvent event(std::uint64_t seq, std::int64_t intended_ns) {
  line::v1::ParcelEvent ev;
  ev.set_seq(seq);
  ev.set_intended_emit_ns(intended_ns);
  return ev;
}

template <Wait W>
void completes_every_record() {
  lowlat::measure::Recorder latency{"handoff-test", "latency"};
  line::Completion done{latency};
  Handoff handoff{W, "handoff-test", "ok", 100, 0ms};
  for (std::uint64_t seq = 0; seq < 1'000; ++seq) {
    done.begin(seq);
    handoff(event(seq, line::monotonic_ns()), done);
  }
  EXPECT_NO_THROW(handoff.drain(done));
  EXPECT_EQ(handoff.published() + handoff.overflow(), 1'000u);
  EXPECT_EQ(done.count(), handoff.published());
}

// A latency below zero throws inside the decide thread (the intended time is an hour ahead). The
// ring then fills up behind the dead thread; drain() must still return, and rethrow.
template <Wait W>
void rethrows_decide_thread_failure() {
  lowlat::measure::Recorder latency{"handoff-test", "latency"};
  line::Completion done{latency};
  Handoff handoff{W, "handoff-test", "negative", 100, 0ms};
  const std::int64_t future_ns = line::monotonic_ns() + 3'600'000'000'000;
  for (std::uint64_t seq = 0; seq < 70'000; ++seq) {
    done.begin(seq);
    handoff(event(seq, future_ns), done);
  }
  EXPECT_THROW(handoff.drain(done), std::runtime_error);
}

TEST(Handoff, ReceiveAndDecideWritersAreOnSeparateLines) { EXPECT_TRUE(Handoff::writers_on_separate_lines()); }
TEST(Handoff, SpinCompletesEveryRecord) { completes_every_record<Wait::spin>(); }
TEST(Handoff, ParkCompletesEveryRecord) { completes_every_record<Wait::park>(); }
TEST(Handoff, SpinRethrowsDecideThreadFailureFromDrain) { rethrows_decide_thread_failure<Wait::spin>(); }
TEST(Handoff, ParkRethrowsDecideThreadFailureFromDrain) { rethrows_decide_thread_failure<Wait::park>(); }

}  // namespace
