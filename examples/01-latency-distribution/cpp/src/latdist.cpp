// latdist-consumer: one receive path, three handling policies (see ../../README.md).
//
//   per-parcel    handle each parcel the moment it arrives.
//   batch-32      hold parcels until 32 have arrived, then handle them together.
//   bimodal-1pct  per-parcel, but seq % 100 == 0 (a scanner no-read) takes a slow
//                 "re-lookup" path of ~2 ms of real CPU work.
//
// The common line consumer (lowlat::line::consume_with) binds, parses, tracks
// sequence gaps and records latency. This file supplies only the handlers.
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <format>
#include <print>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "lowlat/line/cli.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/signals.hpp"

namespace {

namespace line = lowlat::line;
using line::monotonic_ns;

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

// --- Handlers: the only per-example code in the receive path ---------------
//
// Each is a line::ParcelHandler: called once per new parcel, completes it via `done`.
// `lane_sink` keeps the lane lookup observable.

class PerParcel {
 public:
  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    lane_sink += line::lane_for(ev.barcode());
    done.complete(ev);
  }
  [[nodiscard]] std::string notes() const { return {}; }

  unsigned lane_sink = 0;
};

// Holds parcels until `size` have arrived, then completes them all at one done time.
class Batch {
 public:
  explicit Batch(std::size_t size) : size_(size) { pending_.reserve(size); }

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    const std::string& barcode = ev.barcode();
    Pending p{.intended_ns = ev.intended_emit_ns(), .barcode = {}};
    if (barcode.size() != p.barcode.size()) throw std::invalid_argument("SSCC must be 18 ASCII digits");
    std::ranges::copy(barcode, p.barcode.begin());  // fixed buffer: no allocation per parcel
    pending_.push_back(p);
    if (pending_.size() >= size_) flush(done);
  }
  void drain(line::Completion& done) { flush(done); }  // a partial last batch still gets handled
  [[nodiscard]] std::string notes() const { return std::format("; batch={}", size_); }

  unsigned lane_sink = 0;

 private:
  struct Pending {
    std::int64_t intended_ns;
    std::array<char, 18> barcode;  // an SSCC-18: exactly 18 digits, held in place
  };

  void flush(line::Completion& done) {
    for (const auto& p : pending_) lane_sink += line::lane_for(std::string_view{p.barcode});
    const auto done_ns = monotonic_ns();  // one completion time for the whole batch
    for (const auto& p : pending_) done.complete(p.intended_ns, done_ns);
    pending_.clear();
  }

  std::size_t size_;
  std::vector<Pending> pending_;
};

// Per-parcel, but one in `every` takes the slow path: a busy loop, not a sleep.
class Bimodal {
 public:
  Bimodal(std::uint64_t every, std::int64_t slow_us) : every_(every) {
    iterations_ = calibrate(slow_us);
    const auto t0 = monotonic_ns();
    (void)spin(iterations_);
    measured_ns_ = monotonic_ns() - t0;
    std::println("calibrated slow path: {} iterations = {:.1f} us", iterations_,
                 static_cast<double>(measured_ns_) / 1e3);
  }

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    lane_sink += line::lane_for(ev.barcode());
    if (ev.seq() % every_ == 0) {
      lane_sink += static_cast<unsigned>(spin(iterations_));  // the re-lookup: real CPU work
      ++slow_count_;
    }
    done.complete(ev);
  }
  [[nodiscard]] std::string notes() const {
    return std::format("; slow_every={}; slow_parcels={}; slow_path_us={:.1f}; busy loop, not sleep", every_,
                       slow_count_, static_cast<double>(measured_ns_) / 1e3);
  }

  unsigned lane_sink = 0;

 private:
  std::uint64_t every_;
  std::uint64_t iterations_ = 0;
  std::int64_t measured_ns_ = 0;
  std::uint64_t slow_count_ = 0;
};

template <line::ParcelHandler H>
void serve(const line::ConsumerConfig& cfg, H& handler) {
  lowlat::measure::Recorder rec{cfg.example, cfg.variant};
  const auto result = line::consume_with(cfg, line::g_stop, rec, handler, [&](int, int) {
    std::println("latdist-consumer: variant {} on {}", cfg.variant, cfg.bind);
    std::fflush(stdout);  // bound: a script reading a redirected stdout waits on this line
  });

  std::println("received {}, dropped {}, reordered {} (stopped: {}) [{}]", result.received, result.dropped,
               result.reordered, result.stopped_by, handler.lane_sink);
  const std::int64_t span_ns = result.last_done_ns - result.first_done_ns;
  // Completions per second x 1000; one completion (or none) spans no time, so there is no rate.
  const std::string mhz =
      span_ns > 0 ? std::to_string(static_cast<std::int64_t>(static_cast<double>(result.completed) * 1e12 /
                                                             static_cast<double>(span_ns)))
                  : "n/a";
  const auto notes =
      std::format("throughput_mhz={}; done_span_ns={}; reordered={}{}", mhz, span_ns, result.reordered, handler.notes());
  rec.print_summary();
  if (cfg.report) rec.write_report(*cfg.report, notes);
}

}  // namespace

int main(int argc, char** argv) {
  using namespace lowlat;
  try {
    // --slow-us is the only flag the common consumer does not know; the rest, with
    // this example's defaults first (a later flag wins), go to the common parser.
    std::vector<std::string_view> args{"--bind",    "127.0.0.1:47210", "--example",
                                       "01-latency-distribution", "--variant", "per-parcel"};
    std::int64_t slow_us = 2000;
    for (int i = 1; i < argc; ++i) {
      if (std::string_view{argv[i]} == "--slow-us" && i + 1 < argc) {
        slow_us = line::cli::number<std::int64_t>("--slow-us", argv[++i]);
        if (slow_us <= 0) line::cli::fail("--slow-us must be > 0");
      } else args.emplace_back(argv[i]);
    }
    const line::ConsumerConfig cfg = line::parse_consumer_args(args);
    if (cfg.report) (void)measure::load_profile();

    line::install_stop_handlers();

    if (cfg.variant == "per-parcel") {
      PerParcel h;
      serve(cfg, h);
    } else if (cfg.variant == "batch-32") {
      Batch h{32};
      serve(cfg, h);
    } else if (cfg.variant == "bimodal-1pct") {
      Bimodal h{100, slow_us};
      serve(cfg, h);
    } else {
      throw std::invalid_argument("--variant: per-parcel | batch-32 | bimodal-1pct");
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "latdist-consumer: {}", e.what());
    return EXIT_FAILURE;
  }
}
