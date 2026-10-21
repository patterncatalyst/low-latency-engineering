// Tests: SSCC check digit, schedule arithmetic, CLI parsing, and an
// end-to-end 1 kHz x 2 s run against a UDP receiver in this process.
#include <gtest/gtest.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <string_view>
#include <thread>
#include <vector>

#include "lowlat/line/config.hpp"
#include "lowlat/line/schedule.hpp"
#include "lowlat/line/simulator.hpp"
#include "lowlat/line/sscc.hpp"
#include "lowlat/line/v1/parcel.pb.h"

namespace line = lowlat::line;

// --- SSCC -------------------------------------------------------------------

TEST(Sscc, KnownGoodCheckDigit) {
  // GS1 General Specifications example: (00) 1 0614141 123456789 7.
  // By hand, weights 3,1,3,... from the right over 10614141123456789:
  // 27+8+21+6+15+4+9+2+3+1+4+1+12+1+0+6+3 = 123 -> check digit 10 - 3 = 7.
  EXPECT_EQ(line::sscc_check_digit("10614141123456789"), 7);
  EXPECT_TRUE(line::is_valid_sscc("106141411234567897"));
  EXPECT_FALSE(line::is_valid_sscc("106141411234567898"));  // wrong check digit
  EXPECT_FALSE(line::is_valid_sscc("10614141123456789"));   // 17 digits
  EXPECT_FALSE(line::is_valid_sscc("10614141123456789x"));  // not a digit
}

TEST(Sscc, LeadingZerosSurviveAndMakeIsValid) {
  const std::string s = line::make_sscc(0, "0614141", 7);
  EXPECT_EQ(s.size(), 18u);
  EXPECT_EQ(s.substr(0, 17), "00614141000000007");
  EXPECT_TRUE(line::is_valid_sscc(s));
  for (std::uint64_t serial = 0; serial < 2000; ++serial) {
    EXPECT_TRUE(line::is_valid_sscc(line::make_sscc(static_cast<int>(serial % 10), "0614141", serial)));
  }
}

TEST(Sscc, RejectsBadBody) {
  EXPECT_THROW((void)line::sscc_check_digit("123"), std::invalid_argument);
  EXPECT_THROW((void)line::make_sscc(10, "0614141", 1), std::invalid_argument);
}

// --- Schedule ---------------------------------------------------------------

TEST(Schedule, IntendedTimes) {
  const line::Schedule s1k{.t0_ns = 5'000'000'000, .rate_hz = 1000};
  EXPECT_EQ(s1k.intended_ns(0), 5'000'000'000);
  EXPECT_EQ(s1k.intended_ns(1), 5'001'000'000);
  EXPECT_EQ(s1k.intended_ns(1999), 5'000'000'000 + 1999 * 1'000'000);

  // Non-divisible rate: each time is floor(i x 1e9 / rate), with no
  // accumulated error however large i gets.
  const line::Schedule s3{.t0_ns = 0, .rate_hz = 3};
  EXPECT_EQ(s3.intended_ns(1), 333'333'333);
  EXPECT_EQ(s3.intended_ns(3), 1'000'000'000);
  EXPECT_EQ(s3.intended_ns(3'000'000), 1'000'000'000'000'000);
}

TEST(Schedule, EncoderTickAndDeadline) {
  // 2.5 m/s x 1000 pulses/m = 2500 ticks per second.
  EXPECT_EQ(line::encoder_tick(1'000'000'000, 2.5, 1000), 2500u);
  EXPECT_EQ(line::encoder_tick(1'000'000, 2.5, 1000), 2u);  // 2.5 ticks -> floor
  EXPECT_EQ(line::encoder_tick(0, 2.5, 1000), 0u);
  EXPECT_DOUBLE_EQ(line::scan_to_divert_ms(1.2, 2.5), 480.0);
}

// --- CLI --------------------------------------------------------------------

TEST(Config, DefaultsAndOverrides) {
  const line::Config d = line::parse_args({});
  EXPECT_EQ(d.rate_hz, 1000u);
  EXPECT_EQ(d.dest, "127.0.0.1:47000");
  EXPECT_EQ(line::parcel_count(d), 10'000u);

  const std::vector<std::string_view> args{"--rate", "500", "--duration", "2.5", "--seed", "7",
                                           "--dest", "127.0.0.1:47999", "--report", "r.json", "--quiet"};
  const line::Config c = line::parse_args(args);
  EXPECT_EQ(c.rate_hz, 500u);
  EXPECT_EQ(line::parcel_count(c), 1250u);
  EXPECT_EQ(c.seed, 7u);
  EXPECT_TRUE(c.quiet);
  ASSERT_TRUE(c.report.has_value());
  EXPECT_EQ(c.report->string(), "r.json");
}

TEST(Config, RejectsBadInput) {
  const auto bad = [](std::vector<std::string_view> a) {
    EXPECT_THROW((void)line::parse_args(a), std::invalid_argument) << a.front();
  };
  bad({"--rate", "0"});
  bad({"--rate", "abc"});
  bad({"--duration", "-1"});
  bad({"--bogus", "1"});
  bad({"--rate"});
  bad({"--dest", "nocolon"});
}

// --- End to end -------------------------------------------------------------

namespace {

// A UDP receiver on an ephemeral loopback port, draining on its own thread.
class Receiver {
 public:
  Receiver() {
    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    EXPECT_GE(fd_, 0);
    const int rcvbuf = 4 << 20;
    ::setsockopt(fd_, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf);
    const timeval timeout{.tv_sec = 0, .tv_usec = 50'000};  // lets the thread notice `stop_`
    ::setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    EXPECT_EQ(::bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof addr), 0);
    socklen_t len = sizeof addr;
    ::getsockname(fd_, reinterpret_cast<sockaddr*>(&addr), &len);
    port_ = ntohs(addr.sin_port);
    thread_ = std::jthread([this] { drain(); });
  }
  ~Receiver() {
    stop_ = true;
    if (thread_.joinable()) thread_.join();
    ::close(fd_);
  }
  [[nodiscard]] std::uint16_t port() const { return port_; }
  [[nodiscard]] std::size_t received() const { return received_.load(); }
  // Valid once the receiver has been stopped (join gives the happens-before).
  std::vector<lowlat::line::v1::ParcelEvent> take() {
    stop_ = true;
    if (thread_.joinable()) thread_.join();
    return std::move(events_);
  }

 private:
  void drain() {
    char buf[2048];
    while (!stop_) {
      const ssize_t n = ::recv(fd_, buf, sizeof buf, 0);
      if (n < 0) continue;  // timeout
      lowlat::line::v1::ParcelEvent ev;
      if (ev.ParseFromArray(buf, static_cast<int>(n))) events_.push_back(std::move(ev));
      else ++unparsable_;
      received_.fetch_add(1);
    }
  }

  int fd_ = -1;
  std::uint16_t port_ = 0;
  std::atomic<bool> stop_{false};
  std::atomic<std::size_t> received_{0};
  std::size_t unparsable_ = 0;
  std::vector<lowlat::line::v1::ParcelEvent> events_;
  std::jthread thread_;
};

}  // namespace

TEST(Simulator, OneKilohertzTwoSeconds) {
  Receiver rx;
  line::Config cfg;
  cfg.rate_hz = 1000;
  cfg.duration_s = 2.0;
  cfg.dest = "127.0.0.1:" + std::to_string(rx.port());

  std::atomic<bool> stop{false};
  lowlat::measure::Recorder lateness{"line-simulator", "emit-lateness"};
  const line::RunResult result = line::run(cfg, stop, lateness);

  EXPECT_EQ(result.sent, 2000u);
  EXPECT_EQ(result.send_errors, 0u);
  EXPECT_FALSE(result.interrupted);
  EXPECT_EQ(lateness.count(), 2000);

  // Loopback delivery is immediate; allow the receiver a moment to drain.
  for (int i = 0; i < 100 && rx.received() < 2000; ++i) std::this_thread::sleep_for(std::chrono::milliseconds{10});
  const auto events = rx.take();

  ASSERT_EQ(events.size(), 2000u) << "datagrams received";
  for (std::size_t i = 0; i < events.size(); ++i) {
    const auto& e = events[i];
    EXPECT_EQ(e.seq(), i);
    EXPECT_TRUE(line::is_valid_sscc(e.barcode())) << e.barcode();
    EXPECT_GE(e.actual_emit_ns(), e.intended_emit_ns() - 1) << "sent before its time";
    EXPECT_LE(e.scan_confidence_permille(), 1000u);
    EXPECT_GT(e.dims().length_mm(), 0u);
    if (i > 0) {
      EXPECT_EQ(e.intended_emit_ns() - events[i - 1].intended_emit_ns(), 1'000'000) << "at seq " << i;
      EXPECT_GE(e.encoder_tick(), events[i - 1].encoder_tick());
    }
  }
  // 1 ms at 2.5 m/s x 1000 ppm = 2.5 ticks per parcel.
  EXPECT_EQ(events[1999].encoder_tick(), 4997u);
}

TEST(Simulator, StopRequestEndsTheRunEarly) {
  Receiver rx;
  line::Config cfg;
  cfg.rate_hz = 100;
  cfg.duration_s = 60.0;
  cfg.dest = "127.0.0.1:" + std::to_string(rx.port());
  std::atomic<bool> stop{false};
  lowlat::measure::Recorder lateness{"line-simulator", "emit-lateness"};
  std::jthread stopper{[&] {
    std::this_thread::sleep_for(std::chrono::milliseconds{300});
    stop = true;
  }};
  const line::RunResult result = line::run(cfg, stop, lateness);
  EXPECT_TRUE(result.interrupted);
  EXPECT_LT(result.sent, 100u);
  EXPECT_GT(result.sent, 0u);
}

TEST(Simulator, NoReceiverIsCountedNotFatal) {
  line::Config cfg;
  cfg.rate_hz = 1000;
  cfg.duration_s = 0.1;
  cfg.dest = "127.0.0.1:1";  // nothing listens: ICMP refusals surface as send errors
  std::atomic<bool> stop{false};
  lowlat::measure::Recorder lateness{"line-simulator", "emit-lateness"};
  const line::RunResult result = line::run(cfg, stop, lateness);
  EXPECT_EQ(result.sent + result.send_errors, 100u);
  EXPECT_EQ(lateness.count(), 100);  // the belt kept its schedule regardless
}
