// Deterministic checks of the receive engines over loopback: the datagrams are queued in the
// socket before the engine starts, so each test sees the same sequence of calls.
#include <arpa/inet.h>
#include <gtest/gtest.h>
#include <sys/socket.h>

#include <array>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <memory>
#include <span>
#include <thread>
#include <vector>

#include "lowlat/io/engines.hpp"
#include "lowlat/io/handoff.hpp"
#include "lowlat/io/sockets.hpp"
#include "lowlat/io/work.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/measure/recorder.hpp"

namespace lowlat::io {
namespace {

constexpr std::uint64_t kParcels = 100;

void use_test_profile() {
  setenv("LOWLAT_PROFILE", LOWLAT_FIXTURES_DIR "/profile.json", 1);
}

flat::Parcel parcel(std::uint64_t seq) {
  flat::Parcel p;
  p.seq = seq;
  p.intended_emit_ns = line::monotonic_ns();
  const char code[] = "003400001234567890";
  std::memcpy(p.barcode.data(), code, p.barcode.size());
  return p;
}

/// Sends parcels [0, count) to `port` from a throwaway socket.
void send_parcels(std::uint16_t port, std::uint64_t count) {
  const int s = ::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  ASSERT_GE(s, 0);
  sockaddr_in to{};
  to.sin_family = AF_INET;
  to.sin_port = htons(port);
  to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  for (std::uint64_t i = 0; i < count; ++i) {
    const auto bytes = flat::encode(parcel(i));
    ASSERT_EQ(::sendto(s, bytes.data(), bytes.size(), 0, reinterpret_cast<const sockaddr*>(&to), sizeof to),
              static_cast<ssize_t>(bytes.size()));
  }
  ::close(s);
}

/// One camera on an ephemeral port with `count` parcels already queued in its socket.
struct Fixture {
  explicit Fixture(std::uint64_t count) : bound{open_udp(0)} {
    use_test_profile();
    cameras.push_back({bound.fd.get(), count, line::SeqTracker{}});
    send_parcels(bound.port, count);
  }
  Bound bound;
  std::vector<Camera> cameras;
  EngineCounters counters;
  measure::Recorder recorder{"12-io-engines", "test"};

  auto handler() {
    return [this](std::size_t camera, std::span<const std::byte> bytes) {
      if (const auto p = accept(cameras[camera], bytes, counters)) decide(*p, counters, recorder);
    };
  }
};

TEST(Counters, SitOnLinesOfTheirOwn) {
  EXPECT_EQ(alignof(EngineCounters) % std::hardware_destructive_interference_size, 0U);
  EXPECT_EQ(sizeof(EngineCounters) % alignof(EngineCounters), 0U);
}

TEST(Work, RejectsAMalformedAndARepeatedDatagram) {
  use_test_profile();
  Camera camera{-1, 10, line::SeqTracker{}};
  EngineCounters counters;
  const auto bytes = flat::encode(parcel(0));
  EXPECT_TRUE(accept(camera, bytes, counters).has_value());
  EXPECT_FALSE(accept(camera, bytes, counters).has_value());                       // seq 0 again: reordered
  EXPECT_FALSE(accept(camera, std::span{bytes}.first(40), counters).has_value());  // wrong size
  EXPECT_EQ(counters.datagrams, 3U);
  EXPECT_EQ(counters.malformed, 1U);
  EXPECT_EQ(camera.tracker.received(), 1U);
}

TEST(Work, DecideLooksUpTheLaneAndKeepsTheResult) {
  use_test_profile();
  EngineCounters counters;
  measure::Recorder recorder{"12-io-engines", "test"};
  const flat::Parcel p = parcel(7);
  decide(p, counters, recorder);
  EXPECT_EQ(counters.parcels, 1U);
  EXPECT_EQ(counters.lanes[line::lane_for(flat::barcode_view(p))], 1U);
  EXPECT_EQ(recorder.count(), 1);
}

TEST(Sockets, TwoSocketsShareAPortWithReusePort) {
  const Bound first = open_udp(0);
  EXPECT_NO_THROW(static_cast<void>(open_udp(first.port)));
}

TEST(Epoll, TwoCallsPerParcelWhenOneDatagramIsReadyPerWake) {
  Fixture f{kParcels};
  run_epoll(f.cameras, f.handler(), f.counters, LoopConfig{});
  EXPECT_EQ(f.counters.parcels, kParcels);
  EXPECT_GE(f.counters.recvmsgs, kParcels);  // one recvmsg per datagram taken
  EXPECT_GE(f.counters.epoll_waits, 1U);
  EXPECT_EQ(f.counters.syscalls(), f.counters.epoll_waits + f.counters.recvmsgs);
  EXPECT_EQ(f.counters.recvmmsgs + f.counters.enters, 0U);
}

TEST(Recvmmsg, ABatchTakesManyDatagramsPerCall) {
  Fixture f{kParcels};
  run_recvmmsg(f.cameras, f.handler(), f.counters, LoopConfig{});
  EXPECT_EQ(f.counters.parcels, kParcels);
  EXPECT_LE(f.counters.recvmmsgs, (kParcels + kBatch - 1) / kBatch + 1);  // 100 queued: 4 full batches and the remainder
  EXPECT_LT(f.counters.syscalls(), kParcels / 4);
}

TEST(Uring, CompletionsAreReapedWithoutASystemCallEach) {
  Fixture f{kParcels};
  auto receiver = UringReceiver::create(f.cameras);
  if (!receiver && (receiver.error() == EPERM || receiver.error() == ENOSYS)) {
    GTEST_SKIP() << "io_uring unavailable (errno " << receiver.error() << "): blocked by seccomp or absent from this kernel";
  }
  ASSERT_TRUE(receiver.has_value()) << "io_uring setup errno " << receiver.error();
  (*receiver)->run(f.handler(), f.counters, LoopConfig{});
  EXPECT_EQ(f.counters.parcels, kParcels);
  EXPECT_GE(f.counters.cqes, kParcels);
  EXPECT_GE(f.counters.enters, 1U);
  EXPECT_LT(f.counters.enters, kParcels / 4);  // far fewer enters than parcels
  EXPECT_EQ(f.counters.epoll_waits + f.counters.recvmsgs + f.counters.recvmmsgs, 0U);
}

TEST(Handoff, EveryParcelCrossesThreadsOnceAndComesOutDecided) {
  use_test_profile();
  constexpr std::size_t kWorkers = 4;
  HandoffPool pool{kWorkers};
  std::vector<EngineCounters> counters(kWorkers);
  std::vector<measure::Recorder> recorders;
  for (std::size_t w = 0; w < kWorkers; ++w) recorders.emplace_back("12-io-engines", "test");
  EngineCounters sender;
  {
    std::vector<std::jthread> workers;
    for (std::size_t w = 0; w < kWorkers; ++w) workers.emplace_back([&, w] { pool.work(w, counters[w], recorders[w]); });
    for (std::uint64_t i = 0; i < 400; ++i) pool.send(parcel(i), sender);
    pool.finish();
  }
  EXPECT_EQ(sender.handoffs, 400U);
  for (std::size_t w = 0; w < kWorkers; ++w) EXPECT_EQ(counters[w].parcels, 100U);  // round robin
}

}  // namespace
}  // namespace lowlat::io
