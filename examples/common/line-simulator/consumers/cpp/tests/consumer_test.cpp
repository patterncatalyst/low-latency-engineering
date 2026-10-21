// Consumer tests. The integration tests bind UDP 127.0.0.1:47101.
#include <arpa/inet.h>
#include <gtest/gtest.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <atomic>
#include <chrono>
#include <future>
#include <string>
#include <string_view>
#include <thread>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/fd.hpp"
#include "lowlat/line/simulator.hpp"

namespace line = lowlat::line;
using namespace std::chrono_literals;

namespace {

constexpr int kPort = 47101;

line::ConsumerConfig test_config() {
  line::ConsumerConfig c;
  c.bind = "127.0.0.1:" + std::to_string(kPort);
  return c;
}

}  // namespace

// --- Gap accounting ---------------------------------------------------------

TEST(SeqTracker, GapsAreDropped) {
  line::SeqTracker t;
  EXPECT_EQ(t.observe(0), line::SeqTracker::Kind::in_order);
  EXPECT_EQ(t.observe(1), line::SeqTracker::Kind::in_order);
  EXPECT_EQ(t.observe(2), line::SeqTracker::Kind::in_order);
  EXPECT_EQ(t.observe(5), line::SeqTracker::Kind::gap);  // 3 and 4 missing
  EXPECT_EQ(t.observe(6), line::SeqTracker::Kind::in_order);
  EXPECT_EQ(t.received(), 5u);
  EXPECT_EQ(t.dropped(), 2u);
  EXPECT_EQ(t.reordered(), 0u);
}

TEST(SeqTracker, RepeatOrLateIsReorderedNotRecounted) {
  line::SeqTracker t;
  for (std::uint64_t s : {0, 1, 2, 5, 6}) (void)t.observe(s);
  EXPECT_EQ(t.observe(6), line::SeqTracker::Kind::reordered);  // repeat
  EXPECT_EQ(t.observe(3), line::SeqTracker::Kind::reordered);  // late arrival of a "dropped" one
  EXPECT_EQ(t.reordered(), 2u);
  EXPECT_EQ(t.received(), 5u);
  EXPECT_EQ(t.dropped(), 2u);
}

TEST(SeqTracker, FirstDatagramAfterZeroCountsTheMissingOnes) {
  line::SeqTracker t;
  EXPECT_EQ(t.observe(3), line::SeqTracker::Kind::gap);
  EXPECT_EQ(t.dropped(), 3u);
}

// --- Lane lookup ------------------------------------------------------------

TEST(Lane, SerialModuloEight) {
  // extension 0, prefix 0614141, serial 000000013, check digit (not used by the lookup)
  EXPECT_EQ(line::lane_for("006141410000000134"), 13u % 8);
  EXPECT_EQ(line::lane_for("006141410000000008"), 0u);
  EXPECT_EQ(line::lane_for("006141419999999997"), 999'999'999u % 8);
  EXPECT_EQ(line::lane_for("906141410000000070"), 7u);  // the extension digit does not matter
}

TEST(Lane, RejectsNonSscc) {
  EXPECT_THROW((void)line::lane_for("12345"), std::invalid_argument);
  EXPECT_THROW((void)line::lane_for("00614141000000013x"), std::invalid_argument);
}

// --- CLI --------------------------------------------------------------------

TEST(ConsumerConfig, DefaultsAndOverrides) {
  const auto d = line::parse_consumer_args({});
  EXPECT_EQ(d.bind, "127.0.0.1:47000");
  EXPECT_EQ(d.rcvbuf, 4 * 1024 * 1024);
  EXPECT_FALSE(d.expect);
  EXPECT_EQ(d.idle_timeout_ms, 2000);
  EXPECT_EQ(d.example, "00-line-consumer");
  EXPECT_EQ(d.variant, "baseline");

  const std::vector<std::string_view> args{"--bind",   "0.0.0.0:1", "--rcvbuf", "65536",  "--expect",
                                           "10",       "--idle-timeout-ms", "50", "--report", "r.json",
                                           "--example", "x",        "--variant", "y"};
  const auto c = line::parse_consumer_args(args);
  EXPECT_EQ(c.bind, "0.0.0.0:1");
  EXPECT_EQ(c.rcvbuf, 65536);
  EXPECT_EQ(c.expect, 10u);
  EXPECT_EQ(c.idle_timeout_ms, 50);
  EXPECT_EQ(c.report->string(), "r.json");
  EXPECT_EQ(c.example, "x");
  EXPECT_EQ(c.variant, "y");
}

TEST(ConsumerConfig, RejectsBadInput) {
  using V = std::vector<std::string_view>;
  EXPECT_THROW((void)line::parse_consumer_args(V{"--bogus", "1"}), std::invalid_argument);
  EXPECT_THROW((void)line::parse_consumer_args(V{"--expect"}), std::invalid_argument);
  EXPECT_THROW((void)line::parse_consumer_args(V{"--expect", "0"}), std::invalid_argument);
  EXPECT_THROW((void)line::parse_consumer_args(V{"--rcvbuf", "abc"}), std::invalid_argument);
  EXPECT_THROW((void)line::parse_consumer_args(V{"--bind", "nocolon"}), std::invalid_argument);
}

// --- Integration ------------------------------------------------------------

// The simulator library at 1 kHz for 2 s into the consumer, in one process:
// the same CLOCK_MONOTONIC, a real UDP socket in between.
TEST(ConsumerIntegration, OneKilohertzTwoSeconds) {
  auto cfg = test_config();
  cfg.expect = 2000;
  std::atomic<bool> stop{false};
  lowlat::measure::Recorder latency{"line-consumer-test", "integration"};

  std::promise<int> granted;
  auto ready = granted.get_future();
  line::ConsumerResult result;
  std::jthread consumer{[&] {
    result = line::consume(cfg, stop, latency, [&](int, int g) { granted.set_value(g); });
  }};
  ASSERT_EQ(ready.wait_for(5s), std::future_status::ready);
  EXPECT_GT(ready.get(), 0);

  line::Config sim;
  sim.rate_hz = 1000;
  sim.duration_s = 2.0;
  sim.dest = cfg.bind;
  std::atomic<bool> sim_stop{false};
  lowlat::measure::Recorder lateness{"line-simulator", "emit-lateness"};
  const line::RunResult sent = line::run(sim, sim_stop, lateness);
  EXPECT_EQ(sent.sent, 2000u);
  consumer.join();

  EXPECT_EQ(result.stopped_by, "expect");
  EXPECT_EQ(latency.count(), 2000);
  EXPECT_EQ(latency.dropped(), 0u);
  EXPECT_EQ(result.dropped, 0u);
  EXPECT_EQ(result.reordered, 0u);
  EXPECT_GE(hdr_min(&latency.histogram()), 0);  // consume() throws on a negative; belt and braces
  std::uint64_t lanes = 0;
  for (const auto n : result.lane_counts) lanes += n;
  EXPECT_EQ(lanes, 2000u);
}

TEST(ConsumerIntegration, IdleTimeoutEndsTheRunAfterTheLastDatagram) {
  auto cfg = test_config();
  cfg.idle_timeout_ms = 200;
  std::atomic<bool> stop{false};
  lowlat::measure::Recorder latency{"line-consumer-test", "idle"};
  std::promise<void> up;
  auto ready = up.get_future();
  line::ConsumerResult result;
  std::jthread consumer{[&] { result = line::consume(cfg, stop, latency, [&](int, int) { up.set_value(); }); }};
  ASSERT_EQ(ready.wait_for(5s), std::future_status::ready);

  line::Config sim;
  sim.rate_hz = 1000;
  sim.duration_s = 0.1;  // 100 parcels, then silence
  sim.dest = cfg.bind;
  std::atomic<bool> sim_stop{false};
  lowlat::measure::Recorder lateness{"line-simulator", "emit-lateness"};
  (void)line::run(sim, sim_stop, lateness);
  consumer.join();
  EXPECT_EQ(result.stopped_by, "idle");
  EXPECT_EQ(latency.count(), 100);
}

TEST(ConsumerIntegration, StopFlagEndsAnIdleWait) {
  auto cfg = test_config();
  std::atomic<bool> stop{false};
  lowlat::measure::Recorder latency{"line-consumer-test", "stop"};
  line::ConsumerResult result;
  std::jthread consumer{[&] { result = line::consume(cfg, stop, latency); }};
  std::this_thread::sleep_for(300ms);
  stop = true;
  consumer.join();
  EXPECT_EQ(result.stopped_by, "signal");
  EXPECT_EQ(latency.count(), 0);
}

TEST(ConsumerIntegration, NegativeLatencyAborts) {
  auto cfg = test_config();
  std::atomic<bool> stop{false};
  lowlat::measure::Recorder latency{"line-consumer-test", "negative"};
  std::promise<void> up;
  auto ready = up.get_future();
  std::promise<bool> threw;
  std::jthread consumer{[&] {
    try {
      (void)line::consume(cfg, stop, latency, [&](int, int) { up.set_value(); });
      threw.set_value(false);
    } catch (const std::runtime_error&) {
      threw.set_value(true);
    }
  }};
  ASSERT_EQ(ready.wait_for(5s), std::future_status::ready);

  // An event stamped an hour in the future: as if from another clock.
  lowlat::line::v1::ParcelEvent ev;
  ev.set_seq(0);
  ev.set_intended_emit_ns(line::monotonic_ns() + 3'600'000'000'000);
  ev.set_barcode("006141410000000008");
  const std::string wire = ev.SerializeAsString();
  line::Fd tx{::socket(AF_INET, SOCK_DGRAM, 0)};
  sockaddr_in to{};
  to.sin_family = AF_INET;
  to.sin_port = htons(kPort);
  inet_pton(AF_INET, "127.0.0.1", &to.sin_addr);
  ASSERT_EQ(::sendto(tx.get(), wire.data(), wire.size(), 0, reinterpret_cast<sockaddr*>(&to), sizeof to),
            static_cast<ssize_t>(wire.size()));

  auto outcome = threw.get_future();
  ASSERT_EQ(outcome.wait_for(5s), std::future_status::ready);
  EXPECT_TRUE(outcome.get());
  EXPECT_EQ(latency.count(), 0);
}
