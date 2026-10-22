// amdahl-cpp: Amdahl's Law with a real serial section.
//
// A fixed batch of parcels is shared among N workers (std::jthread). Each
// parcel costs CPU work that parallelises, then updates the shared sort-plan
// table under ONE std::mutex: the serial fraction. The fraction is measured,
// not assumed: an instrumented one-worker run times every lock section and
// divides by the wall time.
//
// Work is done in waves (a worker scans its K parcels, all workers meet at a
// barrier, then every worker commits its K updates under the lock, and they
// meet again). The barriers are what make the serial part strictly serial.
// Without them a lock section overlaps the other workers' parallel work and
// the run beats the formula; --sync free runs that variant to show it. The
// prediction is
//     S(N) = 1 / ((1 - p) + p / N),  p = 1 - s the parallel fraction,
// compared with the measured ratio of median wall times (HdrHistogram p50 of
// --reps repetitions per N, variant amdahl-n<N>). See ../README.md.
#include <algorithm>
#include <array>
#include <barrier>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <format>
#include <fstream>
#include <mutex>
#include <numeric>
#include <print>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "lowlat/ch02/model.hpp"
#include "lowlat/line/cli.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/measure/recorder.hpp"

namespace {

using lowlat::line::monotonic_ns;
namespace cli = lowlat::line::cli;

struct Options {
  std::uint64_t batch = 3200;           // parcels per repetition
  std::uint64_t round_parcels = 160;     // parcels per worker per wave
  bool phased = true;                   // barriers between the parallel and serial parts
  std::uint64_t parallel_iters = 20000; // CPU work per parcel outside the lock
  std::uint64_t lock_iters = 2300;      // table updates per parcel inside the lock
  int reps = 30;
  int warmup = 3;
  int calibration_runs = 5;
  std::vector<unsigned> workers{1, 2, 4};
  std::string report_dir = ".";
  std::string example = "02-littles-amdahl";
};

constexpr std::size_t kCells = 64;  // the sort-plan table: lane/chute counters

// The sort-plan table. Updates are additions, so the final contents do not
// depend on which worker got there first: every N must produce the same sum.
struct SortPlan {
  std::mutex lock;
  std::array<std::uint64_t, kCells> cell{};
  void reset() { cell.fill(0); }
  [[nodiscard]] std::uint64_t checksum() const { return std::accumulate(cell.begin(), cell.end(), std::uint64_t{0}); }
};

// Parallel part: a dependent integer mix keyed by the parcel number, so the
// optimiser cannot remove or hoist it. The result is the parcel's weight.
[[gnu::noinline]] std::uint64_t scan_work(std::uint64_t parcel, std::uint64_t iters) {
  std::uint64_t x = parcel * 0x9E3779B97F4A7C15ULL + 1;
  for (std::uint64_t i = 0; i < iters; ++i) {
    x ^= x >> 29;
    x *= 0xBF58476D1CE4E5B9ULL;
  }
  return x;
}

// Pins `value` as computed at this point. scan_work has no side effects, so
// without this the compiler is free to sink the call into the locked region
// (it is only used there) and the "parallel" work would be counted as serial.
// This is the DoNotOptimize idiom of the benchmark harnesses (Ch4), not
// something application code needs.
inline void keep(std::uint64_t& value) { asm volatile("" : "+r"(value) : : "memory"); }

// Serial part, called with the lock held: add the parcel's weight to cells
// of the plan. Each addition depends on the previous (indices chain through
// the weight), so the section has a stable length.
void update_plan(SortPlan& plan, std::uint64_t weight, std::uint64_t iters) {
  std::uint64_t w = weight;
  for (std::uint64_t j = 0; j < iters; ++j) {
    const std::size_t at = (w >> 7) % kCells;
    plan.cell[at] += (w & 0xFFFF) + j;
    w = w * 6364136223846793005ULL + 1442695040888963407ULL;
  }
}

// One worker's share of every wave: parcels base+id, base+id+N, ... (K of
// them). Returns ns spent inside the lock when Timed (the clock is read only
// in the calibration runs).
template <bool Timed>
std::int64_t worker(SortPlan& plan, const Options& o, unsigned id, unsigned n, std::barrier<>& wave) {
  std::int64_t in_lock_ns = 0;
  std::vector<std::uint64_t> weight(o.round_parcels);
  for (std::uint64_t base = 0; base < o.batch; base += std::uint64_t{n} * o.round_parcels) {
    for (std::uint64_t j = 0; j < o.round_parcels; ++j) {  // parallel part
      std::uint64_t w = scan_work(base + id + j * n, o.parallel_iters);
      keep(w);
      weight[j] = w;
    }
    if (o.phased) wave.arrive_and_wait();  // nobody commits while anyone is still scanning
    for (const std::uint64_t w : weight) {  // serial part: one lock section per parcel
      std::scoped_lock guard{plan.lock};
      if constexpr (Timed) {
        const std::int64_t t0 = monotonic_ns();
        update_plan(plan, w, o.lock_iters);
        in_lock_ns += monotonic_ns() - t0;
      } else {
        update_plan(plan, w, o.lock_iters);
      }
    }
    if (o.phased) wave.arrive_and_wait();  // nobody scans the next wave while anyone is still committing
  }
  return in_lock_ns;
}

struct Run {
  std::int64_t wall_ns;
  std::int64_t in_lock_ns;  // only in a Timed run
};

template <bool Timed>
Run run_batch(SortPlan& plan, const Options& o, unsigned n) {
  plan.reset();
  std::vector<std::int64_t> lock_ns(n, 0);
  std::barrier<> wave{static_cast<std::ptrdiff_t>(n)};
  const std::int64_t t0 = monotonic_ns();
  {
    std::vector<std::jthread> pool;
    pool.reserve(n);
    for (unsigned id = 0; id < n; ++id) {
      pool.emplace_back([&, id] { lock_ns[id] = worker<Timed>(plan, o, id, n, wave); });
    }
  }  // jthread joins here
  const std::int64_t wall = monotonic_ns() - t0;
  return {wall, std::accumulate(lock_ns.begin(), lock_ns.end(), std::int64_t{0})};
}

Options parse(int argc, char** argv) {
  Options o;
  for (int i = 1; i < argc; i += 2) {
    const std::string_view opt = argv[i];
    if (i + 1 >= argc) cli::fail(std::format("{} needs a value", opt));
    const std::string_view val = argv[i + 1];
    if (opt == "--batch") o.batch = cli::number<std::uint64_t>(opt, val);
    else if (opt == "--parallel-iters") o.parallel_iters = cli::number<std::uint64_t>(opt, val);
    else if (opt == "--lock-iters") o.lock_iters = cli::number<std::uint64_t>(opt, val);
    else if (opt == "--round-parcels") o.round_parcels = cli::number<std::uint64_t>(opt, val);
    else if (opt == "--reps") o.reps = cli::number<int>(opt, val);
    else if (opt == "--sync") {
      if (val != "phased" && val != "free") cli::fail("--sync is 'phased' or 'free'");
      o.phased = val == "phased";
    }
    else if (opt == "--report-dir") o.report_dir = val;
    else if (opt == "--example") o.example = val;
    else cli::fail(std::format("unknown option '{}'", opt));
  }
  return o;
}

}  // namespace

int main(int argc, char** argv) try {
  const Options o = parse(argc, argv);
  (void)lowlat::measure::load_profile();  // a number without a profile is not publishable
  std::filesystem::create_directories(o.report_dir);
  for (const unsigned n : o.workers) {
    if (o.batch % (std::uint64_t{n} * o.round_parcels) != 0) {
      throw std::invalid_argument(std::format("--batch must be a multiple of N x --round-parcels for N={}", n));
    }
  }
  const std::string tag = o.phased ? "amdahl" : "amdahl-free";
  SortPlan plan;

  // The reference table: what one worker produces. Every N must match it.
  (void)run_batch<false>(plan, o, 1);
  const std::uint64_t reference = plan.checksum();

  // Serial fraction s = time inside the lock / wall time, at N = 1. Ratio of sums
  // over the calibration runs.
  std::int64_t lock_total = 0, wall_total = 0;
  for (int i = 0; i < o.calibration_runs; ++i) {
    const Run r = run_batch<true>(plan, o, 1);
    lock_total += r.in_lock_ns;
    wall_total += r.wall_ns;
  }
  const double s = static_cast<double>(lock_total) / static_cast<double>(wall_total);
  std::println("amdahl-cpp: batch {} parcels, serial fraction s = {:.4f} (time in lock / wall, N=1, {} instrumented runs); "
               "ideal limit 1/s = {:.2f}x",
               o.batch, s, o.calibration_runs, 1.0 / s);

  // Repetitions are interleaved (N=1, 2, 4, N=1, 2, 4, ...) so that a change in
  // background load during the run lands on every N alike.
  std::vector<lowlat::measure::Recorder> recs;
  for (const unsigned n : o.workers) recs.emplace_back(o.example, std::format("{}-n{}", tag, n));
  for (int i = -o.warmup; i < o.reps; ++i) {
    for (std::size_t k = 0; k < o.workers.size(); ++k) {
      const Run r = run_batch<false>(plan, o, o.workers[k]);
      if (plan.checksum() != reference) {
        throw std::runtime_error(std::format("N={}: sort-plan table differs from the one-worker table", o.workers[k]));
      }
      if (i >= 0) recs[k].record(r.wall_ns);
    }
  }
  std::vector<std::int64_t> p50;
  for (const auto& rec : recs) p50.push_back(hdr_value_at_percentile(&rec.histogram(), 50.0));

  for (std::size_t k = 0; k < o.workers.size(); ++k) {
    const unsigned n = o.workers[k];
    const double predicted = lowlat::ch02::amdahl_speedup(s, n);
    const double measured = static_cast<double>(p50.front()) / static_cast<double>(p50[k]);
    const nlohmann::json model = {
        {"law", "Amdahl: S(N) = 1 / ((1 - p) + p / N), p = 1 - s"},
        {"workers", n},
        {"serial_fraction_modelling_input", s},
        {"serial_fraction_basis", "time inside the lock / wall time, one worker, instrumented runs"},
        {"predicted_speedup", predicted},
        {"measured_speedup_p50", measured},
        {"relative_error", (measured - predicted) / predicted},
        {"wall_p50_ns_n1", p50.front()},
        {"wall_p50_ns", p50[k]},
        {"batch_parcels", o.batch},
        {"lock", "std::mutex"},
        {"sync", o.phased ? "phased: barriers between the parallel and serial parts of a wave" : "free: no barriers"},
        {"parcels_per_worker_per_wave", o.round_parcels},
    };
    const auto path = std::filesystem::path{o.report_dir} / std::format("cpp-{}-n{}.json", tag, n);
    recs[k].write_report(path,
                         std::format("{} repetitions after {} warm-up; wall time of the whole batch incl. thread start; repetitions interleaved across N; sync={}",
                                     o.reps, o.warmup, o.phased ? "phased" : "free"),
                         model);
    recs[k].print_summary();
    std::println("  N={}: predicted {:.2f}x, measured {:.2f}x (p50 wall {:.1f} ms), error {:+.1f}%", n, predicted, measured,
                 static_cast<double>(p50[k]) / 1e6, (measured - predicted) / predicted * 100.0);
  }
  return EXIT_SUCCESS;
} catch (const std::exception& e) {
  std::println(stderr, "amdahl-cpp: {}", e.what());
  return EXIT_FAILURE;
}
