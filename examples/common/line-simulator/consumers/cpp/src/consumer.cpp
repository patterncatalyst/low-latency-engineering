#include "lowlat/line/consumer.hpp"

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <format>
#include <memory>
#include <stdexcept>
#include <system_error>

#include "lowlat/line/cli.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/line/fd.hpp"

namespace lowlat::line {
namespace {

// Longest the receive blocks before the loop re-checks the stop flag. A signal
// normally ends the wait at once (EINTR); the tick only closes the window
// between testing the flag and entering recv.
constexpr int kTickMs = 100;

// A bound IPv4 UDP socket with the receive timeout set.
Fd open_bound(const std::string& bind_to, int rcvbuf, int tick_ms, int& granted) {
  const auto colon = bind_to.rfind(':');
  if (colon == std::string::npos) throw std::runtime_error("--bind must be host:port");
  const std::string host = bind_to.substr(0, colon);
  const std::string port = bind_to.substr(colon + 1);

  addrinfo hints{};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  hints.ai_flags = AI_PASSIVE;
  addrinfo* raw = nullptr;
  if (const int rc = ::getaddrinfo(host.c_str(), port.c_str(), &hints, &raw); rc != 0) {
    throw std::runtime_error(std::format("cannot resolve {}: {}", bind_to, ::gai_strerror(rc)));
  }
  const std::unique_ptr<addrinfo, decltype(&::freeaddrinfo)> addr{raw, &::freeaddrinfo};

  Fd fd{::socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol)};
  if (fd.get() < 0) throw std::system_error(errno, std::generic_category(), "socket");

  // Set before bind so the buffer is sized from the first datagram on. Linux
  // caps the request at net.core.rmem_max (never changed here) and doubles it
  // for bookkeeping overhead, so read back what was granted.
  if (::setsockopt(fd.get(), SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf) != 0) {
    throw std::system_error(errno, std::generic_category(), "setsockopt SO_RCVBUF");
  }
  socklen_t len = sizeof granted;
  if (::getsockopt(fd.get(), SOL_SOCKET, SO_RCVBUF, &granted, &len) != 0) {
    throw std::system_error(errno, std::generic_category(), "getsockopt SO_RCVBUF");
  }

  const timeval tv{.tv_sec = tick_ms / 1000, .tv_usec = (tick_ms % 1000) * 1000};
  if (::setsockopt(fd.get(), SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) != 0) {
    throw std::system_error(errno, std::generic_category(), "setsockopt SO_RCVTIMEO");
  }
  if (::bind(fd.get(), addr->ai_addr, addr->ai_addrlen) != 0) {
    throw std::system_error(errno, std::generic_category(), std::format("bind {}", bind_to));
  }
  return fd;
}

int bound_port_of(int fd) {
  sockaddr_in sa{};
  socklen_t len = sizeof sa;
  if (::getsockname(fd, reinterpret_cast<sockaddr*>(&sa), &len) != 0) {
    throw std::system_error(errno, std::generic_category(), "getsockname");
  }
  return ntohs(sa.sin_port);
}

}  // namespace

// --- CLI --------------------------------------------------------------------

ConsumerConfig parse_consumer_args(std::span<const std::string_view> args) {
  using cli::fail;
  using cli::number;
  ConsumerConfig c;
  for (std::size_t i = 0; i < args.size(); ++i) {
    const std::string_view opt = args[i];
    if (!opt.starts_with("--")) fail(std::format("unexpected argument '{}'", opt));
    if (i + 1 >= args.size()) fail(std::format("{} needs a value", opt));
    const std::string_view val = args[++i];

    if (opt == "--bind") {
      if (val.find(':') == std::string_view::npos) fail("--bind must be host:port");
      c.bind = val;
    } else if (opt == "--rcvbuf") {
      c.rcvbuf = number<int>(opt, val);
      if (c.rcvbuf <= 0) fail("--rcvbuf must be > 0");
    } else if (opt == "--expect") {
      c.expect = number<std::uint64_t>(opt, val);
      if (*c.expect == 0) fail("--expect must be > 0");
    } else if (opt == "--idle-timeout-ms") {
      c.idle_timeout_ms = number<int>(opt, val);
      if (c.idle_timeout_ms <= 0) fail("--idle-timeout-ms must be > 0");
    } else if (opt == "--report") {
      if (val.empty()) fail("--report needs a file name");
      c.report = std::filesystem::path{val};
    } else if (opt == "--example") {
      if (val.empty()) fail("--example needs a name");
      c.example = val;
    } else if (opt == "--variant") {
      if (val.empty()) fail("--variant needs a name");
      c.variant = val;
    } else {
      fail(std::format("unknown option '{}'", opt));
    }
  }
  return c;
}

std::string_view consumer_usage() noexcept {
  return R"(usage: line-consumer [options]

  --bind HOST:PORT       UDP address to receive on (IPv4)         [127.0.0.1:47000]
  --rcvbuf BYTES         SO_RCVBUF request; the granted size is printed [4194304]
  --expect N             stop after N datagrams (received + dropped)
  --idle-timeout-ms MS   stop after MS with nothing received, once the
                         first datagram has arrived              [2000]
  --report FILE          write the latency report (needs $LOWLAT_PROFILE)
  --example NAME         report example name                     [00-line-consumer]
  --variant NAME         report variant name                     [baseline]
  -h, --help             this text
)";
}

// --- Accounting and work ----------------------------------------------------

SeqTracker::Kind SeqTracker::observe(std::uint64_t seq) noexcept {
  if (seq < next_) {
    ++reordered_;
    return Kind::reordered;
  }
  ++received_;
  const bool gap = seq > next_;
  dropped_ += seq - next_;
  next_ = seq + 1;
  return gap ? Kind::gap : Kind::in_order;
}

unsigned lane_for(std::string_view sscc) {
  constexpr std::size_t kSerialAt = 8, kSerialLen = 9;  // extension + 7-digit prefix come first
  const bool digits = std::ranges::all_of(sscc, [](char c) { return c >= '0' && c <= '9'; });
  if (sscc.size() != 18 || !digits) throw std::invalid_argument("SSCC must be 18 ASCII digits");
  std::uint64_t serial = 0;
  for (const char c : sscc.substr(kSerialAt, kSerialLen)) serial = serial * 10 + static_cast<unsigned>(c - '0');
  return static_cast<unsigned>(serial % kLanes);
}

// --- Receive loop -----------------------------------------------------------

ConsumerResult consume(const ConsumerConfig& cfg, const std::atomic<bool>& stop, measure::Recorder& latency,
                       const ReadyFn& on_ready) {
  ConsumerResult result;
  const int tick_ms = std::min(kTickMs, cfg.idle_timeout_ms);
  const Fd sock = open_bound(cfg.bind, cfg.rcvbuf, tick_ms, result.granted_rcvbuf);
  if (on_ready) on_ready(bound_port_of(sock.get()), result.granted_rcvbuf);

  SeqTracker tracker;
  v1::ParcelEvent ev;
  std::array<char, 2048> datagram{};
  std::int64_t last_rx_ns = 0;
  bool started = false;
  std::uint64_t booked_dropped = 0;

  while (true) {
    if (stop.load(std::memory_order_relaxed)) {
      result.stopped_by = "signal";
      break;
    }
    if (cfg.expect && tracker.received() + tracker.dropped() >= *cfg.expect) {
      result.stopped_by = "expect";
      break;
    }

    const ssize_t n = ::recv(sock.get(), datagram.data(), datagram.size(), 0);
    if (n < 0) {
      if (errno == EINTR) continue;  // loop head sees the stop flag
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        const std::int64_t waited_ns = monotonic_ns() - last_rx_ns;
        if (started && waited_ns >= std::int64_t{cfg.idle_timeout_ms} * 1'000'000) {
          result.stopped_by = "idle";
          break;
        }
        continue;
      }
      throw std::system_error(errno, std::generic_category(), "recv");
    }
    started = true;

    // Skipped datagrams still count as activity for the idle timeout.
    if (!ev.ParseFromArray(datagram.data(), static_cast<int>(n))) {
      ++result.malformed;
      last_rx_ns = monotonic_ns();
      continue;
    }
    if (tracker.observe(ev.seq()) == SeqTracker::Kind::reordered) {
      last_rx_ns = monotonic_ns();
      continue;
    }

    ++result.lane_counts[lane_for(ev.barcode())];  // the r01 "work"

    const std::int64_t done_ns = monotonic_ns();
    last_rx_ns = done_ns;
    const std::int64_t latency_ns = done_ns - ev.intended_emit_ns();
    if (latency_ns < 0) {
      throw std::runtime_error(std::format(
          "negative latency {} ns at seq {}: the simulator and consumer are not on the same CLOCK_MONOTONIC "
          "(different host or VM?)",
          latency_ns, ev.seq()));
    }
    latency.record(latency_ns);
    latency.add_dropped(tracker.dropped() - booked_dropped);
    booked_dropped = tracker.dropped();
  }

  result.received = tracker.received();
  result.dropped = tracker.dropped();
  result.reordered = tracker.reordered();
  return result;
}

std::string notes_for(const ConsumerResult& r, const ConsumerConfig& cfg) {
  return std::format("reordered={}; rcvbuf_requested={}; rcvbuf_granted={}", r.reordered, cfg.rcvbuf,
                     r.granted_rcvbuf);
}

}  // namespace lowlat::line
