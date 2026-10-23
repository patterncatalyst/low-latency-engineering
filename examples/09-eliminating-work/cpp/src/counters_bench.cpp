// counters-bench: five scan-tunnel camera threads bump their own counters; a telemetry thread samples them.
//
//   --variant adjacent-counters   the five cameras' counters back to back (16 B each: four per line)
//   --variant pair-padded         one camera per 128-byte pair of lines
//   --variant line-padded         one camera per 64-byte line (observed: does the adjacent line matter?)
//   --variant smt-siblings        adjacent layout, two cameras on the two hardware threads of one core
//                                 (observed: siblings share L1, so there is nothing to ping-pong)
//   (--adjacent-counters, --line-padded and --smt-siblings are spellings of --variant NAME.)
//
// Each camera thread is pinned to its own CPU (--cpus: one CPU per camera, then the telemetry thread's) and
// records the time of every batch of 1,000 increments. verify.sh picks the CPUs with distinct_cores (or
// smt_pair) and checks the placement from /proc while the threads hold after the run. Run under
// `perf_region`, the counted region is the cameras' run, so L1 misses per increment come with the report.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <latch>
#include <print>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "lowlat/eliminating/counters.hpp"
#include "lowlat/eliminating/perf_region.hpp"
#include "lowlat/eliminating/placement.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/measure/recorder.hpp"
#include "lowlat/measure/runtime.hpp"

namespace {

using namespace lowlat::eliminating;
using lowlat::line::monotonic_ns;
namespace measure = lowlat::measure;

constexpr std::size_t kBatch = 1'000;       // increments per timed sample
constexpr std::size_t kNoReadEvery = 32;    // one scan in 32 is a no-read

struct Options {
  std::string variant;
  std::vector<int> cpus;  // one per camera, then the telemetry thread's
  std::size_t cameras = kCameras;
  std::size_t batches = 20'000;
  bool rmw = false;  // --increment rmw: fetch_add instead of the single-writer load+store
  int hold_ms = 0;
  std::filesystem::path out;
  std::string example = "09-eliminating-work";
};

struct Placed {
  pid_t tid = 0;
  int cpu = 0;
  const char* role = "";
};

// The placement line of a thread other than the caller (the thread's own tid, recorded when it pinned itself).
void announce_thread(const Placed& p) {
  const std::string line = "placement pid=" + std::to_string(::getpid()) + " tid=" + std::to_string(p.tid) +
                           " cpu=" + std::to_string(p.cpu) + " role=" + p.role;
  std::println("{}", line);
  if (const char* path = std::getenv("LOWLAT_PLACEMENT_FILE")) std::ofstream{path, std::ios::app} << line << '\n';
}

template <class Camera>
int run(const Options& o) {
  const auto bank = make_bank<Camera>();
  std::vector<std::vector<std::int64_t>> batch_ns(o.cameras, std::vector<std::int64_t>(o.batches));
  std::vector<Placed> placed(o.cameras + 1);

  std::latch ready{static_cast<std::ptrdiff_t>(o.cameras + 1)};  // cameras and telemetry are pinned and running
  std::latch done{static_cast<std::ptrdiff_t>(o.cameras)};
  std::atomic<bool> go{false};
  std::atomic<bool> release{false};
  std::atomic<bool> stop_telemetry{false};
  std::atomic<std::uint64_t> telemetry_samples{0};

  std::vector<std::jthread> threads;
  for (std::size_t c = 0; c < o.cameras; ++c) {
    threads.emplace_back([&, c] {
      pin_current_thread(o.cpus[c]);
      placed[c] = {current_tid(), o.cpus[c], "camera"};
      ready.count_down();
      go.wait(false);
      Camera& cam = (*bank)[c];
      for (std::size_t b = 0; b < o.batches; ++b) {
        const std::int64_t t0 = monotonic_ns();
        for (std::size_t i = 0; i < kBatch; ++i) {
          const bool no_read = i % kNoReadEvery == kNoReadEvery - 1;
          if (o.rmw) {
            no_read ? cam.add_no_read() : cam.add_read();
          } else {
            no_read ? cam.bump_no_read() : cam.bump_read();
          }
        }
        batch_ns[c][b] = monotonic_ns() - t0;
      }
      done.count_down();
      release.wait(false);  // parked (asleep) so verify.sh can read where this thread last ran
    });
  }
  // Telemetry: samples every camera's total about once a millisecond, off the cameras' path.
  threads.emplace_back([&] {
    pin_current_thread(o.cpus[o.cameras]);
    placed[o.cameras] = {current_tid(), o.cpus[o.cameras], "telemetry"};
    ready.count_down();
    std::uint64_t sink = 0;
    while (!stop_telemetry.load(std::memory_order_relaxed)) {
      for (std::size_t c = 0; c < o.cameras; ++c) sink += (*bank)[c].total();
      telemetry_samples.fetch_add(1, std::memory_order_relaxed);
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
    release.wait(false);
    if (sink == 1) std::println("");  // keeps the samples observable
  });

  ready.wait();
  const PerfRegion perf;
  perf.enable();
  go.store(true);
  go.notify_all();
  done.wait();
  perf.disable();
  stop_telemetry.store(true);

  for (const Placed& p : placed) announce_thread(p);
  std::fflush(stdout);
  if (o.hold_ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds{o.hold_ms});
  release.store(true);
  release.notify_all();
  threads.clear();  // jthread joins

  // Each counter had one writer, so every total is exact once the threads have joined.
  const std::uint64_t per_camera = o.batches * kBatch;
  for (std::size_t c = 0; c < o.cameras; ++c) {
    if ((*bank)[c].total() != per_camera) throw std::runtime_error("a camera lost increments");
  }

  measure::Recorder recorder{o.example, "counters-" + o.variant};
  for (const auto& per_thread : batch_ns) {
    for (const std::int64_t ns : per_thread) recorder.record(ns);
  }
  const bool siblings = o.variant == "smt-siblings";
  nlohmann::json runtime;
  runtime["counters"] = measure::counters({{"cameras", static_cast<std::int64_t>(o.cameras)},
                                           {"batch_size", static_cast<std::int64_t>(kBatch)},
                                           {"batches_per_camera", static_cast<std::int64_t>(o.batches)},
                                           {"increments", static_cast<std::int64_t>(per_camera * o.cameras)},
                                           {"bytes_per_camera", static_cast<std::int64_t>(sizeof(Camera))},
                                           {"telemetry_samples", static_cast<std::int64_t>(telemetry_samples.load())}});
  runtime["placement"] = measure::placement(o.cpus, !siblings, siblings);
  PerfRegion::report_ops(per_camera * o.cameras);
  recorder.print_summary();
  recorder.write_report(o.out,
                        "op=counters; one sample = one batch of " + std::to_string(kBatch) + " increments by one camera thread (" +
                            std::to_string(o.cameras) + " cameras, each thread pinned; " +
                            (o.rmw ? "increment=fetch_add" : "increment=single writer per counter, relaxed load+store, no read-modify-write") +
                            "); a telemetry thread samples every camera about once per millisecond",
                        std::nullopt, runtime);
  std::println("report: {}", o.out.string());
  return EXIT_SUCCESS;
}

constexpr std::string_view kUsage =
    "usage: counters-bench --variant adjacent-counters|pair-padded|line-padded|smt-siblings --cpus C0,C1,...,TELEMETRY\n"
    "                      --out FILE [--cameras N] [--batches N] [--hold-ms MS] [--increment store|rmw] [--example NAME]\n";

Options parse(std::span<const std::string_view> args) {
  Options o;
  const auto value = [&](std::size_t& i) -> std::string_view {
    if (i + 1 >= args.size()) throw std::invalid_argument("missing value for " + std::string{args[i]});
    return args[++i];
  };
  for (std::size_t i = 0; i < args.size(); ++i) {
    const std::string_view a = args[i];
    if (a == "--variant") o.variant = value(i);
    else if (a == "--adjacent-counters" || a == "--line-padded" || a == "--smt-siblings") o.variant = a.substr(2);
    else if (a == "--cpus") o.cpus = parse_cpu_list(value(i));
    else if (a == "--out") o.out = value(i);
    else if (a == "--cameras") o.cameras = std::stoull(std::string{value(i)});
    else if (a == "--batches") o.batches = std::stoull(std::string{value(i)});
    else if (a == "--hold-ms") o.hold_ms = std::stoi(std::string{value(i)});
    else if (a == "--increment") {
      const std::string_view kind = value(i);
      if (kind != "store" && kind != "rmw") throw std::invalid_argument("--increment must be store or rmw");
      o.rmw = kind == "rmw";
    }
    else if (a == "--example") o.example = value(i);
    else throw std::invalid_argument("unknown option " + std::string{a});
  }
  if (o.variant != "adjacent-counters" && o.variant != "pair-padded" && o.variant != "line-padded" &&
      o.variant != "smt-siblings") {
    throw std::invalid_argument("unknown --variant " + o.variant);
  }
  if (o.cameras < 1 || o.cameras > kCameras) throw std::invalid_argument("--cameras must be 1..5");
  if (o.cpus.size() != o.cameras + 1) throw std::invalid_argument("--cpus needs one CPU per camera plus one for telemetry");
  if (o.out.empty()) throw std::invalid_argument("--out FILE is required");
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
    if (o.variant == "pair-padded") return run<PairPaddedCamera>(o);
    if (o.variant == "line-padded") return run<LinePaddedCamera>(o);
    return run<AdjacentCamera>(o);
  } catch (const std::exception& e) {
    std::println(stderr, "counters-bench: {}\n{}", e.what(), kUsage);
    return EXIT_FAILURE;
  }
}
