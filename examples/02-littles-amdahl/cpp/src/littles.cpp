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
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <format>
#include <print>
#include <random>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>

#include "lowlat/ch02/model.hpp"
#include "lowlat/line/cli.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
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
  if (o.rate_hz <= 0 || o.sample_us <= 0 || o.duration_s <= 0 || !(o.service_mean_us > 0.0)) {
    cli::fail("--rate, --sample-us, --duration and --service-mean-us must be > 0");
  }
  return o;
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

// The per-parcel hook for lowlat::line::consume_with. On the first parcel it
// anchors the schedule and starts the sampler; for each parcel it spends a drawn
// service time, completes the parcel, and keeps the sum of W for the model block.
class LittlesHandler {
 public:
  explicit LittlesHandler(const Options& o)
      : o_(o), service_us_{1.0 / o.service_mean_us}, cap_us_(10.0 * o.service_mean_us), rng_{o.seed} {}

  void operator()(const lowlat::line::v1::ParcelEvent& ev, lowlat::line::Completion& completion) {
    if (!sampler_.joinable()) {
      // Parcel `seq` is due at t0 + seq/lambda, so t0 follows from any first parcel.
      const auto seq = static_cast<std::int64_t>(ev.seq());
      t0_ns_ = ev.intended_emit_ns() - seq * 1'000'000'000 / o_.rate_hz;
      sampler_ = std::jthread{[this](std::stop_token st) { sampled_ = sample_in_system(st, done_, t0_ns_, o_); }};
    }
    serve(static_cast<std::int64_t>(std::min(service_us_(rng_), cap_us_) * 1000.0));
    const std::int64_t done_ns = monotonic_ns();
    done_.fetch_add(1, std::memory_order_release);
    completion.complete(ev.intended_emit_ns(), done_ns);  // throws on a negative W
    w_sum_ns_ += static_cast<long double>(done_ns - ev.intended_emit_ns());
  }

  // End of run: the sampler ends at t0 + duration; join also publishes `sampled_`.
  void drain(lowlat::line::Completion&) {
    if (sampler_.joinable()) sampler_.join();
  }

  [[nodiscard]] const Sampled& sampled() const noexcept { return sampled_; }
  [[nodiscard]] long double w_sum_ns() const noexcept { return w_sum_ns_; }

 private:
  const Options& o_;
  std::exponential_distribution<double> service_us_;
  double cap_us_;  // a service time is bounded, as a retry count is
  std::mt19937_64 rng_;
  std::atomic<std::int64_t> done_{0};
  std::int64_t t0_ns_ = 0;
  Sampled sampled_;
  long double w_sum_ns_ = 0;  // sum of W: input to the model block only, never reported as a latency
  std::jthread sampler_;      // last: stopped and joined first if the run unwinds
};

}  // namespace

int main(int argc, char** argv) try {
  const Options o = parse(argc, argv);
  if (!o.report.empty()) (void)lowlat::measure::load_profile();  // fail before the run

  lowlat::line::ConsumerConfig cfg;
  cfg.bind = std::format("127.0.0.1:{}", o.port);
  cfg.expect = static_cast<std::uint64_t>(o.rate_hz) * static_cast<std::uint64_t>(o.duration_s);
  // idle_timeout_ms: 2 s after the last parcel the run is over (the default).

  lowlat::measure::Recorder latency{o.example, o.variant};
  LittlesHandler handler{o};
  const std::atomic<bool> no_stop{false};  // this program is stopped by --duration or by idling, not by a signal

  std::println("littles-consumer: 127.0.0.1:{}, lambda={} /s, service mean {} us (offered utilisation {:.2f})",
               o.port, o.rate_hz, o.service_mean_us, o.rate_hz * o.service_mean_us / 1e6);

  const lowlat::line::ConsumerResult run = lowlat::line::consume_with(cfg, no_stop, latency, handler);
  const std::int64_t received = static_cast<std::int64_t>(run.completed);
  const std::int64_t dropped = static_cast<std::int64_t>(run.dropped);
  const Sampled& sampled = handler.sampled();
  if (received == 0 || sampled.samples == 0) throw std::runtime_error("no parcels received");

  // --- the model block: the only place a mean appears ---------------------
  const double lambda = static_cast<double>(o.rate_hz);
  const double w_mean_s = static_cast<double>(handler.w_sum_ns() / received) / 1e9;
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
    // The model block rides in the kit's report; it is not added to the JSON here.
    latency.write_report(o.report,
                         std::format("received={} dropped={} seed={}; W recorded per parcel as done - "
                                     "intended emit time",
                                     received, dropped, o.seed),
                         model);
    std::println("report: {}", o.report);
  }
  return EXIT_SUCCESS;
} catch (const std::exception& e) {
  std::println(stderr, "littles-consumer: {}", e.what());
  return EXIT_FAILURE;
}
