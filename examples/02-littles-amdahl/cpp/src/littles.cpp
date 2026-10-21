// littles-consumer: Little's Law on the parcel line (L = lambda * W).
//
// A single-server consumer whose handling takes a variable (exponential)
// service time. Two things are measured at once, independently:
//   W  per parcel: done - intended emit time, recorded in the HdrHistogram kit.
//   L  by sampling: every --sample-us, the parcels in the system, i.e. due by
//      the belt's schedule but not yet done, are counted.
// The time-average L, the offered rate lambda and the mean W go into the
// report's `model` block (the only place a mean may appear), with the
// prediction lambda * W. See ../README.md.
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <format>
#include <print>
#include <random>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <vector>

#include "lowlat/ch02/model.hpp"
#include "lowlat/line/cli.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/line/fd.hpp"
#include "lowlat/line/v1/parcel.pb.h"
#include "lowlat/measure/recorder.hpp"

namespace {

using lowlat::line::monotonic_ns;
using lowlat::line::sleep_until_ns;
namespace cli = lowlat::line::cli;

struct Options {
  int port = 47220;
  std::int64_t rate_hz = 1000;       // offered rate lambda; must match the simulator
  int duration_s = 10;               // sampling window = the simulator's run length
  double service_mean_us = 600.0;    // mean of the exponential service time
  std::int64_t sample_us = 997;      // L sampling interval: not a divisor of the 1 ms arrival period
  std::uint64_t seed = 7;
  double budget_ms = 480.0;          // scan-to-divert budget for the warehouse framing
  double belt_mps = 2.5;
  std::string report;
  std::string example = "02-littles-amdahl";
  std::string variant = "littles-law";
};

Options parse(int argc, char** argv) {
  Options o;
  for (int i = 1; i < argc; i += 2) {
    const std::string_view opt = argv[i];
    if (i + 1 >= argc) cli::fail(std::format("{} needs a value", opt));
    const std::string_view val = argv[i + 1];
    if (opt == "--port") o.port = cli::number<int>(opt, val);
    else if (opt == "--rate") o.rate_hz = cli::number<std::int64_t>(opt, val);
    else if (opt == "--duration") o.duration_s = cli::number<int>(opt, val);
    else if (opt == "--service-mean-us") o.service_mean_us = cli::number<double>(opt, val);
    else if (opt == "--sample-us") o.sample_us = cli::number<std::int64_t>(opt, val);
    else if (opt == "--seed") o.seed = cli::number<std::uint64_t>(opt, val);
    else if (opt == "--budget-ms") o.budget_ms = cli::number<double>(opt, val);
    else if (opt == "--belt-mps") o.belt_mps = cli::number<double>(opt, val);
    else if (opt == "--report") o.report = val;
    else if (opt == "--example") o.example = val;
    else if (opt == "--variant") o.variant = val;
    else cli::fail(std::format("unknown option '{}'", opt));
  }
  return o;
}

lowlat::line::Fd open_socket(int port) {
  lowlat::line::Fd fd{::socket(AF_INET, SOCK_DGRAM, 0)};
  if (fd.get() < 0) throw std::system_error(errno, std::generic_category(), "socket");
  const int rcvbuf = 4 * 1024 * 1024;
  ::setsockopt(fd.get(), SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf);
  const timeval tv{.tv_sec = 0, .tv_usec = 100'000};
  ::setsockopt(fd.get(), SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<std::uint16_t>(port));
  inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
  if (::bind(fd.get(), reinterpret_cast<sockaddr*>(&sa), sizeof sa) != 0) {
    throw std::system_error(errno, std::generic_category(), std::format("bind 127.0.0.1:{}", port));
  }
  return fd;
}

// What the sampler thread hands back through join().
struct Sampled {
  std::int64_t sum_in_system = 0;
  std::int64_t samples = 0;
  std::int64_t max_in_system = 0;
};

// Count the parcels in the system at fixed intervals. The interval is 997 us,
// deliberately not a divisor of the 1 ms arrival period: a sampler locked to a
// deterministic arrival stream always sees the same phase (just after an
// arrival) and over-counts by about half a parcel; the drifting phase samples
// every point of the arrival cycle equally, which Little's Law assumes.
// A parcel is in the system when it is due by the schedule
// (arrivals_by) minus done. The sample is taken at the instant the clock is
// read, not at the nominal tick, so a late wake-up cannot skew the pairing.
Sampled sample_in_system(std::stop_token stop, const std::atomic<std::int64_t>& done, std::int64_t t0_ns,
                         const Options& o) {
  Sampled s;
  const std::int64_t end_ns = t0_ns + std::int64_t{o.duration_s} * 1'000'000'000;
  for (std::int64_t tick = t0_ns; tick < end_ns && !stop.stop_requested(); tick += o.sample_us * 1000) {
    if (!sleep_until_ns(tick)) continue;
    const std::int64_t now = monotonic_ns();
    const std::int64_t in_system = lowlat::ch02::arrivals_by(now, t0_ns, o.rate_hz) -
                                   done.load(std::memory_order_acquire);
    s.sum_in_system += in_system;
    s.max_in_system = std::max(s.max_in_system, in_system);
    ++s.samples;
  }
  return s;
}

// The per-parcel "handling": spin for a drawn service time. A busy-wait on the
// monotonic clock stands in for CPU work whose length varies parcel to parcel
// (re-reads, label retries); a sleep would add timer slack to every parcel.
void serve(std::int64_t service_ns) {
  const std::int64_t until = monotonic_ns() + service_ns;
  while (monotonic_ns() < until) {
  }
}

}  // namespace

int main(int argc, char** argv) try {
  const Options o = parse(argc, argv);
  if (!o.report.empty()) (void)lowlat::measure::load_profile();  // fail before the run
  const lowlat::line::Fd sock = open_socket(o.port);
  const std::int64_t expect = o.rate_hz * o.duration_s;

  lowlat::measure::Recorder latency{o.example, o.variant};
  std::mt19937_64 rng{o.seed};
  std::exponential_distribution<double> service_us{1.0 / o.service_mean_us};
  const double cap_us = 10.0 * o.service_mean_us;  // a service time is bounded, as a retry count is

  std::atomic<std::int64_t> done{0};
  std::jthread sampler;
  Sampled sampled;
  std::int64_t t0_ns = 0, received = 0, dropped = 0, next_seq = 0, last_rx_ns = 0;
  long double w_sum_ns = 0;  // sum of W: input to the model block only, never reported as a latency
  lowlat::line::v1::ParcelEvent ev;
  std::array<char, 2048> dg{};

  std::println("littles-consumer: 127.0.0.1:{}, lambda={} /s, service mean {} us (offered utilisation {:.2f})",
               o.port, o.rate_hz, o.service_mean_us, o.rate_hz * o.service_mean_us / 1e6);

  while (received + dropped < expect) {
    const ssize_t n = ::recv(sock.get(), dg.data(), dg.size(), 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (last_rx_ns != 0 && monotonic_ns() - last_rx_ns > 2'000'000'000) break;  // idle: the run is over
        continue;
      }
      throw std::system_error(errno, std::generic_category(), "recv");
    }
    if (!ev.ParseFromArray(dg.data(), static_cast<int>(n))) continue;
    const auto seq = static_cast<std::int64_t>(ev.seq());
    if (seq < next_seq) continue;  // reordered
    dropped += seq - next_seq;
    next_seq = seq + 1;

    if (!sampler.joinable()) {
      // Parcel `seq` is due at t0 + seq/lambda, so t0 follows from any first parcel.
      t0_ns = ev.intended_emit_ns() - seq * 1'000'000'000 / o.rate_hz;
      sampler = std::jthread{[&](std::stop_token st) { sampled = sample_in_system(st, done, t0_ns, o); }};
    }
    serve(static_cast<std::int64_t>(std::min(service_us(rng), cap_us) * 1000.0));
    const std::int64_t done_ns = monotonic_ns();
    last_rx_ns = done_ns;
    done.fetch_add(1, std::memory_order_release);
    ++received;

    const std::int64_t w_ns = done_ns - ev.intended_emit_ns();
    if (w_ns < 0) throw std::runtime_error("negative latency: simulator and consumer not on one CLOCK_MONOTONIC");
    latency.record(w_ns);
    w_sum_ns += static_cast<long double>(w_ns);
  }
  latency.add_dropped(static_cast<std::uint64_t>(dropped));
  if (sampler.joinable()) {
    sampler.join();  // the sampler ends at t0 + duration; join also publishes `sampled`
  }
  if (received == 0 || sampled.samples == 0) throw std::runtime_error("no parcels received");

  // --- the model block: the only place a mean appears ---------------------
  const double lambda = static_cast<double>(o.rate_hz);
  const double w_mean_s = static_cast<double>(w_sum_ns / received) / 1e9;
  const double l_sampled = static_cast<double>(sampled.sum_in_system) / static_cast<double>(sampled.samples);
  const double l_predicted = lowlat::ch02::littles_L(lambda, w_mean_s);
  const double rel_err = (l_sampled - l_predicted) / l_predicted;
  const double belt_m = o.belt_mps * o.budget_ms / 1000.0;
  const nlohmann::json model = {
      {"law", "Little: L = lambda * W"},
      {"lambda_per_s", lambda},
      {"L_sampled_time_average", l_sampled},
      {"W_mean_seconds_modelling_input", w_mean_s},
      {"predicted_L", l_predicted},
      {"relative_error", rel_err},
      {"samples", sampled.samples},
      {"sample_interval_us", o.sample_us},
      {"max_in_system", sampled.max_in_system},
      {"service_mean_us", o.service_mean_us},
      {"offered_utilisation", lambda * o.service_mean_us / 1e6},
      {"warehouse",
       {{"scan_to_divert_budget_ms", o.budget_ms},
        {"belt_mps", o.belt_mps},
        {"belt_metres_in_budget", belt_m},
        {"in_flight_parcels", lowlat::ch02::littles_L(lambda, o.budget_ms / 1000.0)}}},
  };

  latency.print_summary();
  std::println("model: lambda={:.0f}/s  L(sampled)={:.3f}  W-bar(model input)={:.3f} ms  predicted L=lambda*W={:.3f}  "
               "error={:+.2f}%  (samples={}, max in system={})",
               lambda, l_sampled, w_mean_s * 1e3, l_predicted, rel_err * 100.0, sampled.samples,
               sampled.max_in_system);
  std::println("warehouse: {:.0f} ms scan-to-divert x {:.0f}/s = {:.0f} parcels in flight on {:.2f} m of belt at {} m/s",
               o.budget_ms, lambda, model["warehouse"]["in_flight_parcels"].get<double>(), belt_m, o.belt_mps);
  if (!o.report.empty()) {
    nlohmann::json doc = latency.report(std::format("received={} dropped={} seed={}; W recorded per parcel as done - "
                                                    "intended emit time",
                                                    received, dropped, o.seed));
    doc["model"] = model;
    std::ofstream out{o.report};
    out << doc.dump(2) << '\n';
    if (!out) throw std::runtime_error("cannot write " + o.report);
    std::println("report: {}", o.report);
  }
  return EXIT_SUCCESS;
} catch (const std::exception& e) {
  std::println(stderr, "littles-consumer: {}", e.what());
  return EXIT_FAILURE;
}
