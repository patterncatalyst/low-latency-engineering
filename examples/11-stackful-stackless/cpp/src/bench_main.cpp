// tasks-bench: the Ch11 micro workloads in C++ (see ../README.md).
//
//   tasks-bench parked     --variant os-thread|fiber|coroutine [--tasks 10000] [--wait-ms 1000]
//   tasks-bench pingpong   --variant os-thread|fiber|coroutine [--rounds 1000000] [--batch 1000]
//                          [--handoff condvar|semaphore]   (os-thread: the primitive the two threads wait on)
//   tasks-bench neighbours --variant os-thread|fiber|coroutine [--tasks 1000] [--iterations 500]
//                          [--blocking-sleep-in-fiber]
//
// Every run takes --cpus (the CPUs the measured threads pin to), --hold-ms (how long the pinned threads wait
// after "placement-ready" so verify.sh can check them in /proc) and --report FILE (a lowlat-report/1).
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <format>
#include <print>
#include <string>
#include <string_view>

#include "lowlat/measure/recorder.hpp"
#include "lowlat/measure/runtime.hpp"
#include "lowlat/tasks/options.hpp"
#include "lowlat/tasks/placement.hpp"
#include "lowlat/tasks/workloads.hpp"

namespace {

namespace tasks = lowlat::tasks;
namespace measure = lowlat::measure;

constexpr std::string_view kExample = "11-stackful-stackless";

int fail(const std::string& what) {
  std::println(stderr, "tasks-bench: {}", what);
  return EXIT_FAILURE;
}


int write(const tasks::Run& run, tasks::Variant v, const tasks::Options& o) {
  measure::Recorder rec{std::string{kExample}, std::string{tasks::name_of(v)}};
  for (const std::int64_t ns : run.samples) rec.record(ns);
  rec.print_summary();
  for (const auto& [key, value] : run.counters) std::println("counter {}={}", key, value);
  const std::string path = o.text("report", "");
  if (path.empty()) return EXIT_SUCCESS;
  nlohmann::json runtime;
  if (!run.cpus.empty()) runtime["placement"] = tasks::placement_of(run.cpus);
  if (!run.counters.empty()) runtime["counters"] = measure::counters(run.counters);
  if (run.ctx_recorded) {
    runtime["ctx_switches"] = {{"voluntary", run.ctx.voluntary}, {"involuntary", run.ctx.involuntary}};
  }
  rec.write_report(std::filesystem::path{path}, run.notes, std::nullopt, runtime);
  std::println("report: {}", path);
  return EXIT_SUCCESS;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return fail("usage: tasks-bench parked|pingpong|neighbours --variant NAME [options]");
  const std::string_view mode{argv[1]};
  auto opts = tasks::Options::parse(argc, argv, 2, {"blocking-sleep-in-fiber"});
  if (!opts) return fail(opts.error());
  const tasks::Options& o = *opts;
  const auto variant = tasks::parse_variant(o.text("variant", ""));
  if (!variant) return fail("--variant: os-thread | fiber | coroutine");

  std::vector<int> cpus;
  if (const std::string list = o.text("cpus", ""); !list.empty()) {
    auto parsed = tasks::parse_cpu_list(list);
    if (!parsed) return fail(parsed.error());
    cpus = *parsed;
  }
  const auto hold = o.number("hold-ms", 0);
  if (!hold) return fail(hold.error());
  if (!o.text("report", "").empty()) {
    try {
      (void)measure::load_profile();
    } catch (const std::exception& e) {
      return fail(e.what());
    }
  }

  std::expected<tasks::Run, std::string> run = std::unexpected("unknown mode");
  if (mode == "parked") {
    const auto n = o.number("tasks", 10'000);
    const auto wait = o.number("wait-ms", 1000);
    if (!n) return fail(n.error());
    if (!wait) return fail(wait.error());
    tasks::ParkedParams p;
    p.tasks = *n;
    p.wait = std::chrono::milliseconds{*wait};
    p.cpu = cpus.empty() ? -1 : cpus.front();
    p.hold = std::chrono::milliseconds{*hold};
    run = tasks::run_parked(*variant, p);
  } else if (mode == "pingpong") {
    const auto rounds = o.number("rounds", 1'000'000);
    const auto batch = o.number("batch", 1000);
    if (!rounds) return fail(rounds.error());
    if (!batch) return fail(batch.error());
    tasks::PingPongParams p;
    p.rounds = *rounds;
    p.batch = *batch;
    p.cpus = cpus;
    p.handoff = o.text("handoff", "condvar");
    p.hold = std::chrono::milliseconds{*hold};
    run = tasks::run_pingpong(*variant, p);
  } else if (mode == "neighbours") {
    const auto n = o.number("tasks", 1000);
    const auto iterations = o.number("iterations", 500);
    if (!n) return fail(n.error());
    if (!iterations) return fail(iterations.error());
    tasks::NeighbourParams p;
    p.tasks = *n;
    p.iterations = *iterations;
    p.blocking_call = o.flag("blocking-sleep-in-fiber");
    p.cpu = cpus.empty() ? -1 : cpus.front();
    p.hold = std::chrono::milliseconds{*hold};
    run = tasks::run_neighbours(*variant, p);
  } else {
    return fail(std::format("unknown mode '{}'", mode));
  }
  if (!run) return fail(run.error());
  return write(*run, *variant, o);
}
