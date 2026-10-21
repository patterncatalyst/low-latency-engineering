// latdist-consumer: one receive path, three handling policies (see ../../README.md).
//
//   per-parcel    handle each parcel the moment it arrives.
//   batch-32      hold parcels until 32 have arrived, then handle them together.
//   bimodal-1pct  per-parcel, but seq % 100 == 0 (a scanner no-read) takes a slow
//                 "re-lookup" path of ~2 ms of real CPU work.
//
// The common line-consumer has no hook between "received" and "done", so this
// copies its minimal receive loop (socket, parse, SeqTracker) and adds the policy.
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <format>
#include <optional>
#include <print>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/fd.hpp"

namespace {

using lowlat::line::monotonic_ns;

std::atomic<bool> g_stop{false};
extern "C" void on_signal(int) { g_stop.store(true, std::memory_order_relaxed); }

enum class Policy { per_parcel, batch, bimodal };

struct Options {
  std::string variant = "per-parcel";
  Policy policy = Policy::per_parcel;
  std::size_t batch = 32;
  std::uint64_t slow_every = 100;
  std::int64_t slow_us = 2000;
  std::string bind_host = "127.0.0.1";
  std::uint16_t bind_port = 47210;
  std::optional<std::uint64_t> expect;
  std::int64_t idle_ms = 2000;
  std::optional<std::filesystem::path> report;
  std::string example = "01-latency-distribution";
};

Options parse(const std::vector<std::string_view>& a) {
  Options o;
  for (std::size_t i = 0; i < a.size(); ++i) {
    const auto opt = a[i];
    if (i + 1 >= a.size()) throw std::invalid_argument(std::format("{} needs a value", opt));
    const std::string val{a[++i]};
    if (opt == "--variant") {
      o.variant = val;
      if (val == "per-parcel") o.policy = Policy::per_parcel;
      else if (val == "batch-32") o.policy = Policy::batch, o.batch = 32;
      else if (val == "bimodal-1pct") o.policy = Policy::bimodal;
      else throw std::invalid_argument("--variant: per-parcel | batch-32 | bimodal-1pct");
    } else if (opt == "--bind") {
      const auto colon = val.rfind(':');
      if (colon == std::string::npos) throw std::invalid_argument("--bind must be host:port");
      o.bind_host = val.substr(0, colon);
      o.bind_port = static_cast<std::uint16_t>(std::stoul(val.substr(colon + 1)));
    } else if (opt == "--expect") o.expect = std::stoull(val);
    else if (opt == "--idle-timeout-ms") o.idle_ms = std::stoll(val);
    else if (opt == "--slow-us") o.slow_us = std::stoll(val);
    else if (opt == "--report") o.report = val;
    else if (opt == "--example") o.example = val;
    else throw std::invalid_argument(std::format("unknown option '{}'", opt));
  }
  return o;
}

// A dependent multiply-add chain: each step needs the previous result, so it can
// neither be vectorised nor folded away, and the empty asm makes `x` observable.
std::uint64_t spin(std::uint64_t iterations) noexcept {
  std::uint64_t x = 0x9e3779b97f4a7c15ULL;
  for (std::uint64_t i = 0; i < iterations; ++i) {
    x = x * 6364136223846793005ULL + 1442695040888963407ULL;
    asm volatile("" : "+r"(x));
  }
  return x;
}

// Iterations of spin() that take `target_us`. Double the count until a run lasts at
// least 20 ms (long enough to swamp the clock read), then time five more runs and keep
// the fastest: a run that was preempted on a busy host measures the scheduler, not the loop.
std::uint64_t calibrate(std::int64_t target_us) {
  std::uint64_t n = 1 << 12;
  double best_iter_per_ns = 0;
  for (int extra = 0; extra < 5;) {
    const auto t0 = monotonic_ns();
    (void)spin(n);
    const auto took_ns = monotonic_ns() - t0;
    best_iter_per_ns = std::max(best_iter_per_ns, static_cast<double>(n) / static_cast<double>(took_ns));
    if (took_ns < 20'000'000) n *= 2;
    else ++extra;
  }
  return static_cast<std::uint64_t>(best_iter_per_ns * static_cast<double>(target_us) * 1000.0);
}

lowlat::line::Fd open_socket(const Options& o) {
  lowlat::line::Fd fd{::socket(AF_INET, SOCK_DGRAM, 0)};
  if (fd.get() < 0) throw std::system_error(errno, std::generic_category(), "socket");
  const int rcvbuf = 4 << 20;
  ::setsockopt(fd.get(), SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf);
  const timeval tv{.tv_sec = 0, .tv_usec = 100'000};
  ::setsockopt(fd.get(), SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(o.bind_port);
  if (::inet_pton(AF_INET, o.bind_host.c_str(), &sa.sin_addr) != 1) throw std::invalid_argument("bad --bind host");
  if (::bind(fd.get(), reinterpret_cast<sockaddr*>(&sa), sizeof sa) != 0) {
    throw std::system_error(errno, std::generic_category(), "bind");
  }
  return fd;
}

}  // namespace

int main(int argc, char** argv) {
  using namespace lowlat;
  try {
    const Options o = parse({argv + 1, argv + argc});
    if (o.report) (void)measure::load_profile();
    struct sigaction sa{};
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);

    std::uint64_t slow_iterations = 0;
    std::int64_t slow_measured_ns = 0;
    if (o.policy == Policy::bimodal) {
      slow_iterations = calibrate(o.slow_us);
      const auto t0 = monotonic_ns();
      (void)spin(slow_iterations);
      slow_measured_ns = monotonic_ns() - t0;
      std::println("calibrated slow path: {} iterations = {:.1f} us", slow_iterations,
                   static_cast<double>(slow_measured_ns) / 1e3);
    }

    const auto sock = open_socket(o);
    std::println("latdist-consumer: variant {} on {}:{}", o.variant, o.bind_host, o.bind_port);
    measure::Recorder rec{o.example, o.variant};
    line::SeqTracker tracker;
    line::v1::ParcelEvent ev;
    std::array<char, 2048> dgram{};

    struct Pending {
      std::int64_t intended_ns;
      std::string barcode;
    };
    std::vector<Pending> pending;
    pending.reserve(o.batch);
    std::int64_t first_done = 0, last_done = 0, last_rx = 0;
    std::uint64_t done_count = 0, slow_count = 0, booked_dropped = 0;
    unsigned lane_sink = 0;  // keeps the lane lookup observable

    const auto finish_parcel = [&](std::int64_t intended_ns, std::int64_t done_ns, std::uint64_t seq) {
      const std::int64_t lat = done_ns - intended_ns;
      if (lat < 0) throw std::runtime_error(std::format("negative latency {} ns at seq {}", lat, seq));
      rec.record(lat);
      if (done_count++ == 0) first_done = done_ns;
      last_done = done_ns;
    };
    const auto flush = [&] {
      for (const auto& p : pending) lane_sink += line::lane_for(p.barcode);
      const auto done_ns = monotonic_ns();  // one completion time for the whole batch
      for (const auto& p : pending) finish_parcel(p.intended_ns, done_ns, 0);
      pending.clear();
    };

    std::string stopped = "signal";
    while (!g_stop.load(std::memory_order_relaxed)) {
      if (o.expect && tracker.received() + tracker.dropped() >= *o.expect) {
        stopped = "expect";
        break;
      }
      const ssize_t n = ::recv(sock.get(), dgram.data(), dgram.size(), 0);
      if (n < 0) {
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
          if (last_rx != 0 && monotonic_ns() - last_rx >= o.idle_ms * 1'000'000) {
            stopped = "idle";
            break;
          }
          continue;
        }
        throw std::system_error(errno, std::generic_category(), "recv");
      }
      last_rx = monotonic_ns();
      if (!ev.ParseFromArray(dgram.data(), static_cast<int>(n))) continue;
      if (tracker.observe(ev.seq()) == line::SeqTracker::Kind::reordered) continue;

      if (o.policy == Policy::batch) {
        pending.push_back({ev.intended_emit_ns(), ev.barcode()});
        if (pending.size() >= o.batch) flush();
      } else {
        lane_sink += line::lane_for(ev.barcode());
        if (o.policy == Policy::bimodal && ev.seq() % o.slow_every == 0) {
          lane_sink += static_cast<unsigned>(spin(slow_iterations));  // the re-lookup: real CPU work
          ++slow_count;
        }
        finish_parcel(ev.intended_emit_ns(), monotonic_ns(), ev.seq());
      }
      rec.add_dropped(tracker.dropped() - booked_dropped);
      booked_dropped = tracker.dropped();
    }
    flush();  // a partial last batch still gets handled

    std::println("received {}, dropped {}, reordered {} (stopped: {}) [{}]", tracker.received(), tracker.dropped(),
                 tracker.reordered(), stopped, lane_sink);
    const double span_s = static_cast<double>(last_done - first_done) / 1e9;
    const auto mhz = static_cast<std::int64_t>(static_cast<double>(done_count) / span_s * 1000.0);
    auto notes = std::format("throughput_mhz={}; done_span_ns={}; reordered={}", mhz, last_done - first_done,
                             tracker.reordered());
    if (o.policy == Policy::batch) notes += std::format("; batch={}", o.batch);
    if (o.policy == Policy::bimodal) {
      notes += std::format("; slow_every={}; slow_parcels={}; slow_path_us={:.1f}; busy loop, not sleep",
                           o.slow_every, slow_count, static_cast<double>(slow_measured_ns) / 1e3);
    }
    rec.print_summary();
    if (o.report) rec.write_report(*o.report, notes);
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "latdist-consumer: {}", e.what());
    return EXIT_FAILURE;
  }
}
