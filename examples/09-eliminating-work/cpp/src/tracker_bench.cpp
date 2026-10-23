// tracker-bench: the Ch9 tracker microbenchmarks, one latency report per run.
//
//   --mode insert   track() + erase() of one parcel at line scale (4,800 in flight, a sliding window):
//                   latency per insert-and-erase pair, and the exact allocations the pair makes.
//   --mode lookup   find_state() of an in-flight parcel in a preloaded tracker, keys visited in a
//                   shuffled order; --size 1000000 is the hub tracker, --size 4800 the line tracker.
//   --mode sweep    sweep_due() over a record table of --size slots: latency per sweep.
//
//   --variant node-map | flat-map                 (insert, lookup)
//   --variant fat-record | hot-cold               (sweep)
//   (--fat-record is accepted as a spelling of --variant fat-record, and so on.)
//
// Every sample is one timed operation recorded into an HdrHistogram; the report carries the exact
// allocation counts and, with --cpu, runtime.placement. Run under `perf_region` (examples/_lib/lib.sh)
// the timed loop is the counted region. --untimed runs the same work once through a function
// cachegrind can single out (CACHEGRIND_FUNCTION=cg_...) and writes no report.
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <map>
#include <optional>
#include <print>
#include <span>
#include <string>
#include <stdexcept>
#include <string_view>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include "lowlat/eliminating/alloc_counter.hpp"
#include "lowlat/eliminating/keys.hpp"
#include "lowlat/eliminating/perf_region.hpp"
#include "lowlat/eliminating/placement.hpp"
#include "lowlat/eliminating/records.hpp"
#include "lowlat/eliminating/tracker.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/measure/recorder.hpp"
#include "lowlat/measure/runtime.hpp"

namespace {

using namespace lowlat::eliminating;
using lowlat::line::monotonic_ns;
namespace measure = lowlat::measure;

constexpr std::uint64_t kKeySeed = 2026;
constexpr std::uint64_t kOrderSeed = 42;
constexpr std::size_t kInsertKeyRing = 65'536;  // distinct keys cycled through by the insert loop
constexpr std::size_t kHubFloor = 100'000;      // from this size on, the working set is "hub"

volatile std::uint64_t g_sink = 0;  // a result the optimiser cannot prove unused

struct Options {
  std::string mode;
  std::string variant;
  std::size_t size = 0;
  std::size_t samples = 0;
  std::optional<int> cpu;
  std::filesystem::path out;
  std::string example = "09-eliminating-work";
  bool untimed = false;
  int hold_ms = 0;
};

struct Outcome {
  measure::Recorder recorder;
  std::map<std::string, std::int64_t> counters;
  std::uint64_t ops = 0;  // operations inside the perf-counted region
  std::string notes;
};

[[nodiscard]] const char* scale_of(std::size_t size) { return size >= kHubFloor ? "hub" : "line"; }

[[nodiscard]] std::string report_variant(const Options& o) {
  const std::string op = o.mode == "insert" ? "insert" : std::string{scale_of(o.size)} + '-' + o.mode;
  return op + '-' + o.variant;
}

// --- insert ---------------------------------------------------------------------------------------------

template <class Tracker>
Outcome run_insert(const Options& o) {
  const Keys keys = make_keys(kInsertKeyRing, kKeySeed);
  const std::size_t window = o.size;  // parcels in flight
  Tracker tracker{window + 64};
  for (std::size_t i = kInsertKeyRing - window; i < kInsertKeyRing; ++i) tracker.track(scan_of(keys, i));

  const auto op = [&](std::size_t i) {
    const std::size_t pos = i % kInsertKeyRing;
    tracker.track(scan_of(keys, pos));
    tracker.erase(keys.text[(pos + kInsertKeyRing - window) % kInsertKeyRing]);
  };
  for (std::size_t i = 0; i < 20'000; ++i) op(i);  // warm up caches and branch predictors

  Outcome out{measure::Recorder{o.example, report_variant(o)}, {}, o.samples, {}};
  const PerfRegion perf;
  perf.enable();
  const alloc::Snapshot before = alloc::snapshot();
  for (std::size_t i = 0; i < o.samples; ++i) {
    const std::int64_t t0 = monotonic_ns();
    op(i + 20'000);
    out.recorder.record(monotonic_ns() - t0);
  }
  const alloc::Snapshot used = alloc::since(before);
  perf.disable();
  g_sink = tracker.size();
  out.counters = {{"inserts", static_cast<std::int64_t>(o.samples)},
                  {"allocations", static_cast<std::int64_t>(used.allocations)},
                  {"allocated_bytes", static_cast<std::int64_t>(used.bytes)},
                  {"in_flight", static_cast<std::int64_t>(tracker.size())}};
  out.notes = "op=insert; one sample = track() of a new parcel plus erase() of the one diverted " +
              std::to_string(window) + " parcels earlier (steady " + std::to_string(window) +
              " in flight); allocations counted by the replaced global operator new on this thread";
  return out;
}

// --- lookup ---------------------------------------------------------------------------------------------

// Cachegrind's view: one function, everything inlined into it, so its costs are the lookups' alone.
// NOLINTNEXTLINE: extern "C" for an unmangled symbol name, which CACHEGRIND_FUNCTION matches exactly.
extern "C" [[gnu::noinline, gnu::flatten, gnu::used]] std::uint64_t cg_lookup_node_map(const NodeTracker& t, const Keys& k,
                                                                                        std::size_t n) {
  std::uint64_t acc = 0;
  for (std::size_t s = 0; s < n; ++s) acc += static_cast<std::uint8_t>(t.find_state(NodeTracker::lookup_key(k, s % k.size())));
  return acc;
}
extern "C" [[gnu::noinline, gnu::flatten, gnu::used]] std::uint64_t cg_lookup_flat_map(const HotColdTracker& t, const Keys& k,
                                                                                        std::size_t n) {
  std::uint64_t acc = 0;
  for (std::size_t s = 0; s < n; ++s) {
    acc += static_cast<std::uint8_t>(t.find_state(HotColdTracker::lookup_key(k, s % k.size())));
  }
  return acc;
}

template <class Tracker>
std::uint64_t cachegrind_lookup(const Tracker& t, const Keys& k, std::size_t n) {
  if constexpr (std::is_same_v<Tracker, NodeTracker>) {
    return cg_lookup_node_map(t, k, n);
  } else {
    return cg_lookup_flat_map(t, k, n);
  }
}

template <class Tracker>
std::optional<Outcome> run_lookup(const Options& o) {
  std::optional<Tracker> tracker;
  alloc::Snapshot build;
  {
    const Keys insertion = make_keys(o.size, kKeySeed);  // input to the build, not part of its footprint
    const alloc::Snapshot before_build = alloc::snapshot();
    tracker.emplace(o.size + o.size / 16);
    for (std::size_t i = 0; i < o.size; ++i) tracker->track(scan_of(insertion, i));
    build = alloc::since(before_build);
  }
  const Keys lookups = make_lookup_keys(o.size, kKeySeed, kOrderSeed);

  // One untimed pass: page faults and TLB fills belong to setup, for both variants alike.
  std::uint64_t acc = 0;
  for (std::size_t j = 0; j < o.size; ++j) {
    acc += static_cast<std::uint8_t>(tracker->find_state(Tracker::lookup_key(lookups, j)));
  }

  if (o.untimed) {
    PerfRegion::report_ops(o.samples);
    g_sink = acc + cachegrind_lookup(*tracker, lookups, o.samples);
    return std::nullopt;
  }

  Outcome out{measure::Recorder{o.example, report_variant(o)}, {}, o.samples, {}};
  const PerfRegion perf;
  perf.enable();
  std::size_t j = 0;
  for (std::size_t s = 0; s < o.samples; ++s) {
    const std::int64_t t0 = monotonic_ns();
    const State state = tracker->find_state(Tracker::lookup_key(lookups, j));
    out.recorder.record(monotonic_ns() - t0);
    acc += static_cast<std::uint8_t>(state);
    if (++j == o.size) j = 0;
  }
  perf.disable();
  g_sink = acc;
  out.counters = {{"parcels", static_cast<std::int64_t>(o.size)},
                  {"lookups", static_cast<std::int64_t>(o.samples)},
                  {"build_allocations", static_cast<std::int64_t>(build.allocations)},
                  {"build_bytes", static_cast<std::int64_t>(build.bytes)}};
  out.notes = std::string{"op="} + scale_of(o.size) + "-lookup; one sample = find_state() of a parcel in flight, " +
              "keys visited in a seeded shuffled order (not the insertion order); " + std::to_string(o.size) +
              " parcels preloaded; one untimed pass first";
  return out;
}

// --- sweep ----------------------------------------------------------------------------------------------

extern "C" [[gnu::noinline, gnu::flatten, gnu::used]] std::uint64_t cg_sweep_fat_record(const FatTable& t, std::uint64_t tick,
                                                                                         std::size_t sweeps) {
  std::uint64_t acc = 0;
  for (std::size_t s = 0; s < sweeps; ++s) acc += t.sweep_due(tick + s);
  return acc;
}
extern "C" [[gnu::noinline, gnu::flatten, gnu::used]] std::uint64_t cg_sweep_hot_cold(const HotColdTable& t, std::uint64_t tick,
                                                                                       std::size_t sweeps) {
  std::uint64_t acc = 0;
  for (std::size_t s = 0; s < sweeps; ++s) acc += t.sweep_due(tick + s);
  return acc;
}

template <class Table>
std::optional<Outcome> run_sweep(const Options& o) {
  Table table;
  alloc::Snapshot build;
  {
    const Keys insertion = make_keys(o.size, kKeySeed);
    const alloc::Snapshot before_build = alloc::snapshot();
    table.reserve(o.size);
    for (std::size_t i = 0; i < o.size; ++i) {
      (void)table.insert(make_record(scan_of(insertion, i), insertion.packed[i]));
    }
    build = alloc::since(before_build);
  }
  const std::uint64_t tick = o.size / 2;  // about half the table is due
  std::uint64_t acc = 0;
  for (int w = 0; w < 3; ++w) acc += table.sweep_due(tick);

  if (o.untimed) {
    PerfRegion::report_ops(o.samples * o.size);
    if constexpr (std::is_same_v<Table, FatTable>) {
      g_sink = acc + cg_sweep_fat_record(table, tick, o.samples);
    } else {
      g_sink = acc + cg_sweep_hot_cold(table, tick, o.samples);
    }
    return std::nullopt;
  }

  Outcome out{measure::Recorder{o.example, report_variant(o)}, {}, o.samples * o.size, {}};
  const PerfRegion perf;
  perf.enable();
  for (std::size_t s = 0; s < o.samples; ++s) {
    const std::int64_t t0 = monotonic_ns();
    const std::size_t due = table.sweep_due(tick);
    out.recorder.record(monotonic_ns() - t0);
    acc += due;
  }
  perf.disable();
  g_sink = acc;
  out.counters = {{"slots", static_cast<std::int64_t>(table.slots())},
                  {"sweeps", static_cast<std::int64_t>(o.samples)},
                  {"build_bytes", static_cast<std::int64_t>(build.bytes)},
                  {"due", static_cast<std::int64_t>(table.sweep_due(tick))}};
  out.notes = std::string{"op="} + scale_of(o.size) + "-sweep; one sample = one sweep_due() over " + std::to_string(o.size) +
              " slots (about half due); hardware counters are per slot swept";
  return out;
}

// --- command line ---------------------------------------------------------------------------------------

constexpr std::string_view kUsage =
    "usage: tracker-bench --mode insert|lookup|sweep --variant NAME [--size N] [--samples N] [--cpu CPU]\n"
    "                     [--out FILE] [--example NAME] [--untimed] [--hold-ms MS]\n"
    "  variants: node-map | flat-map (insert, lookup); fat-record | hot-cold (sweep)\n"
    "  --fat-record, --hot-cold, --node-map and --flat-map are spellings of --variant NAME\n";

Options parse(std::span<const std::string_view> args) {
  Options o;
  const auto value = [&](std::size_t& i) -> std::string_view {
    if (i + 1 >= args.size()) throw std::invalid_argument("missing value for " + std::string{args[i]});
    return args[++i];
  };
  const auto number = [](std::string_view v) { return static_cast<std::size_t>(std::stoull(std::string{v})); };
  for (std::size_t i = 0; i < args.size(); ++i) {
    const std::string_view a = args[i];
    if (a == "--mode") o.mode = value(i);
    else if (a == "--variant") o.variant = value(i);
    else if (a == "--node-map" || a == "--flat-map" || a == "--fat-record" || a == "--hot-cold") o.variant = a.substr(2);
    else if (a == "--size") o.size = number(value(i));
    else if (a == "--samples") o.samples = number(value(i));
    else if (a == "--cpu") o.cpu = static_cast<int>(number(value(i)));
    else if (a == "--out") o.out = value(i);
    else if (a == "--example") o.example = value(i);
    else if (a == "--untimed") o.untimed = true;
    else if (a == "--hold-ms") o.hold_ms = static_cast<int>(number(value(i)));
    else throw std::invalid_argument("unknown option " + std::string{a});
  }
  const bool maps = o.variant == "node-map" || o.variant == "flat-map";
  const bool records = o.variant == "fat-record" || o.variant == "hot-cold";
  if (o.mode == "sweep" ? !records : !(maps && (o.mode == "insert" || o.mode == "lookup"))) {
    throw std::invalid_argument("--mode " + o.mode + " does not take --variant " + o.variant);
  }
  if (o.size == 0) o.size = o.mode == "insert" ? 4'800 : 1'000'000;
  if (o.samples == 0) o.samples = o.mode == "sweep" ? 200 : (o.mode == "insert" ? 200'000 : 1'000'000);
  if (!o.untimed && o.out.empty()) throw std::invalid_argument("--out FILE is required (or --untimed)");
  return o;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const std::vector<std::string_view> args(argv + 1, argv + argc);
    for (const auto a : args) {
      if (a == "-h" || a == "--help") {
        std::print("{}", kUsage);
        return EXIT_SUCCESS;
      }
    }
    const Options o = parse(args);
    if (o.cpu) pin_current_thread(*o.cpu);

    std::optional<Outcome> outcome;
    if (o.mode == "insert") {
      outcome = o.variant == "node-map" ? run_insert<NodeTracker>(o) : run_insert<HotColdTracker>(o);
    } else if (o.mode == "lookup") {
      outcome = o.variant == "node-map" ? run_lookup<NodeTracker>(o) : run_lookup<HotColdTracker>(o);
    } else {
      outcome = o.variant == "fat-record" ? run_sweep<FatTable>(o) : run_sweep<HotColdTable>(o);
    }
    if (!outcome) return EXIT_SUCCESS;  // --untimed: cachegrind is reading the counts

    // The thread ran pinned; verify.sh reads this line while the process holds, and checks /proc.
    if (o.cpu) {
      announce_placement(*o.cpu, "bench");
      if (o.hold_ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds{o.hold_ms});
    }
    nlohmann::json runtime;
    runtime["counters"] = measure::counters(outcome->counters);
    if (o.cpu) {
      const int cpus[] = {*o.cpu};
      runtime["placement"] = measure::placement(cpus, true, false);
    }
    if (outcome->ops > 0) PerfRegion::report_ops(outcome->ops);
    outcome->recorder.print_summary();
    outcome->recorder.write_report(o.out, outcome->notes, std::nullopt, runtime);
    std::println("report: {}", o.out.string());
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "tracker-bench: {}\n{}", e.what(), kUsage);
    return EXIT_FAILURE;
  }
}
