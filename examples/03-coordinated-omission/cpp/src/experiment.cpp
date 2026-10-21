#include "lowlat/co/experiment.hpp"

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>

#include <array>
#include <atomic>
#include <cerrno>
#include <format>
#include <memory>
#include <stdexcept>
#include <system_error>
#include <thread>

#include "lowlat/line/cli.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/fd.hpp"
#include "lowlat/line/v1/parcel.pb.h"

namespace lowlat::co {
namespace {

using line::monotonic_ns;

std::string variant(std::string_view base, const std::string& suffix) { return std::string{base} + suffix; }

line::Fd open_bound(const Config& cfg) {
  const auto colon = cfg.bind.rfind(':');
  if (colon == std::string::npos) throw std::invalid_argument("--bind must be host:port");
  addrinfo hints{};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  hints.ai_flags = AI_PASSIVE;
  addrinfo* raw = nullptr;
  if (const int rc = ::getaddrinfo(cfg.bind.substr(0, colon).c_str(), cfg.bind.substr(colon + 1).c_str(), &hints, &raw);
      rc != 0) {
    throw std::runtime_error(std::format("cannot resolve {}: {}", cfg.bind, ::gai_strerror(rc)));
  }
  const std::unique_ptr<addrinfo, decltype(&::freeaddrinfo)> addr{raw, &::freeaddrinfo};
  line::Fd fd{::socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol)};
  if (fd.get() < 0) throw std::system_error(errno, std::generic_category(), "socket");
  ::setsockopt(fd.get(), SOL_SOCKET, SO_RCVBUF, &cfg.rcvbuf, sizeof cfg.rcvbuf);
  const timeval tick{.tv_sec = 0, .tv_usec = 100'000};  // bounds the idle check
  ::setsockopt(fd.get(), SOL_SOCKET, SO_RCVTIMEO, &tick, sizeof tick);
  if (::bind(fd.get(), addr->ai_addr, addr->ai_addrlen) != 0) {
    throw std::system_error(errno, std::generic_category(), std::format("bind {}", cfg.bind));
  }
  return fd;
}

// Keeps the compiler from deleting the work of a closed-loop request.
std::atomic<unsigned> g_sink{0};

}  // namespace

Config parse_args(std::span<const std::string_view> args) {
  using line::cli::fail;
  using line::cli::number;
  Config c;
  for (std::size_t i = 0; i < args.size(); ++i) {
    const std::string_view opt = args[i];
    if (!opt.starts_with("--")) fail(std::format("unexpected argument '{}'", opt));
    if (i + 1 >= args.size()) fail(std::format("{} needs a value", opt));
    const std::string_view val = args[++i];
    if (opt == "--bind") {
      c.bind = val;
    } else if (opt == "--expect") {
      c.expect = number<std::uint64_t>(opt, val);
    } else if (opt == "--stall-ms") {
      c.stall_ms = number<std::int64_t>(opt, val);
    } else if (opt == "--stall-seq") {
      c.stall_seq = number<std::uint64_t>(opt, val);
    } else if (opt == "--suffix") {
      c.suffix = val;
    } else if (opt == "--out") {
      c.out_dir = val;
    } else {
      fail(std::format("unknown option '{}'", opt));
    }
  }
  if (c.expect == 0) fail("--expect must be > 0");
  if (c.stall_ms < 0) fail("--stall-ms must be >= 0");
  return c;
}

Recorders::Recorders(const std::string& suffix)
    : receipt_time{std::string{kExample}, variant("receipt-time", suffix)},
      intended_time{std::string{kExample}, variant("intended-time", suffix)},
      closed_loop_corrected{std::string{kExample}, variant("closed-loop-corrected", suffix)},
      closed_loop_naive{std::string{kExample}, variant("closed-loop-naive", suffix)} {}

void stall_for(std::chrono::milliseconds d) { std::this_thread::sleep_for(d); }

std::uint64_t run_receive(const Config& cfg, Recorders& rec) {
  const line::Fd sock = open_bound(cfg);
  line::SeqTracker tracker;
  line::v1::ParcelEvent ev;
  std::array<char, 2048> datagram{};
  std::int64_t last_rx_ns = 0;
  bool started = false;

  while (tracker.received() + tracker.dropped() < cfg.expect) {
    const ssize_t n = ::recv(sock.get(), datagram.data(), datagram.size(), 0);
    // The datagram has just been dequeued: this is where a service-side timer
    // starts its clock, however long the parcel waited in the socket buffer.
    const std::int64_t dequeued_ns = monotonic_ns();
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (started && dequeued_ns - last_rx_ns >= std::int64_t{cfg.idle_timeout_ms} * 1'000'000) break;
        continue;
      }
      throw std::system_error(errno, std::generic_category(), "recv");
    }
    started = true;
    last_rx_ns = dequeued_ns;
    if (!ev.ParseFromArray(datagram.data(), static_cast<int>(n))) continue;
    if (tracker.observe(ev.seq()) == line::SeqTracker::Kind::reordered) continue;

    g_sink.store(line::lane_for(ev.barcode()), std::memory_order_relaxed);  // the line's "handle" step
    if (cfg.stall_ms > 0 && ev.seq() == cfg.stall_seq) stall_for(std::chrono::milliseconds{cfg.stall_ms});

    const std::int64_t done_ns = monotonic_ns();
    rec.receipt_time.record(done_ns - dequeued_ns);
    rec.intended_time.record(done_ns - ev.intended_emit_ns());
  }
  rec.receipt_time.add_dropped(tracker.dropped());
  rec.intended_time.add_dropped(tracker.dropped());
  return tracker.dropped();
}

void run_closed_loop(const Config& cfg, std::uint64_t requests, Recorders& rec) {
  constexpr std::string_view barcode = "006141410000000134";
  const std::int64_t interval_ns = kExpectedInterval.count();
  for (std::uint64_t i = 0; i < requests; ++i) {
    const std::int64_t start_ns = monotonic_ns();
    g_sink.store(line::lane_for(barcode), std::memory_order_relaxed);
    if (cfg.stall_ms > 0 && i == cfg.stall_seq) stall_for(std::chrono::milliseconds{cfg.stall_ms});
    const std::int64_t latency_ns = monotonic_ns() - start_ns;

    rec.closed_loop_naive.record(latency_ns);
    rec.closed_loop_corrected.record_corrected(latency_ns, interval_ns);

    // Closed loop: the next request is issued only now, at least one interval
    // after this one started. Nothing queues behind the stall, so nothing is
    // measured as having waited.
    (void)line::sleep_until_ns(start_ns + interval_ns);
  }
}

void run_clock_probe(std::uint64_t calls, ClockProbe& probe) {
  // Two reads back to back: the difference is the cost of one read.
  for (std::uint64_t i = 0; i < calls; ++i) {
    const std::int64_t a = monotonic_ns();
    const std::int64_t b = monotonic_ns();
    probe.line_monotonic_ns.record(b - a);
  }
  for (std::uint64_t i = 0; i < calls; ++i) {
    const auto a = std::chrono::steady_clock::now();
    const auto b = std::chrono::steady_clock::now();
    probe.steady_clock.record(std::chrono::duration_cast<std::chrono::nanoseconds>(b - a));
  }
}

}  // namespace lowlat::co
