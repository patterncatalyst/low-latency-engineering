// busy-pool: a pool of busy decide workers, for the quota-against-cpuset lane.
//
//   busy-pool [--workers N] [--seconds S] [--out FILE]
//
// N defaults to std::thread::hardware_concurrency(), the "one worker per hardware thread" rule: on the
// 4-vCPU guest that is 4 whatever the container is allowed, which is the point. Every worker spins on
// a modelled decide step (a 64-bit mix standing in for the tracker lookup) until stopped, so the pool
// offers more CPU time than --cpus=2 grants (CFS bandwidth throttling) and more threads than
// --cpuset-cpus=2,3 has CPUs (time-slicing, no throttling). It runs until SIGTERM or SIGINT, or for
// --seconds. On exit it writes per-worker iteration counts and CPU time (lowlat-pool/1). Busy-spinning
// is the opposite of what a decide path should do; here it is the load that makes the limit visible.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <ctime>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <functional>
#include <new>
#include <stdexcept>
#include <print>
#include <stop_token>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/signals.hpp"
#include "lowlat/lockfree/options.hpp"
#include "sink.hpp"

namespace {

namespace line = lowlat::line;

/// One worker's counters: written by that worker only, padded so two workers never share a line
/// (2 x the destructive-interference size: the L2 spatial prefetcher pulls adjacent line pairs).
struct alignas(2 * std::hardware_destructive_interference_size) WorkerStats {
  std::uint64_t iterations = 0;
  std::int64_t start_ns = 0;
  std::int64_t cpu_ns = 0;
};
static_assert(sizeof(WorkerStats) % alignof(WorkerStats) == 0);

/// Start gate: every worker arrives and spins until all have, then reads the clock. A futex-based
/// std::latch can wake a worker a millisecond late on an idle core; spinning brings the clock reads together.
class SpinGate {
 public:
  explicit SpinGate(int workers) noexcept : workers_(workers) {}
  [[nodiscard]] std::int64_t arrive_and_go() noexcept {
    arrived_.fetch_add(1, std::memory_order_acq_rel);
    while (arrived_.load(std::memory_order_acquire) < workers_) {
#if defined(__x86_64__)
      __builtin_ia32_pause();  // spin-wait hint: eases the sibling hyperthread and the loop's exit
#endif
    }
    return line::monotonic_ns();
  }

 private:
  alignas(2 * std::hardware_destructive_interference_size) std::atomic<int> arrived_{0};
  int workers_;
};

[[nodiscard]] std::int64_t thread_cpu_ns() noexcept {
  timespec ts{};
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return static_cast<std::int64_t>(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

/// splitmix64: the modelled decide step.
[[nodiscard]] constexpr std::uint64_t mix(std::uint64_t x) noexcept {
  x += 0x9E3779B97F4A7C15ULL;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
  return x ^ (x >> 31);
}

void worker(const std::stop_token& stop, WorkerStats& stats, SpinGate& gate, std::uint64_t seed) {
  std::uint64_t x = seed;
  stats.start_ns = gate.arrive_and_go();
  while (!stop.stop_requested()) {
    for (int i = 0; i < 4096; ++i) x = mix(x);
    ++stats.iterations;
  }
  stats.cpu_ns = thread_cpu_ns();
  lowlat::place::sink(x);
}

int run(const lowlat::lockfree::Options& options) {
  const std::size_t workers = options.number("workers", std::thread::hardware_concurrency());
  const std::uint64_t seconds = options.number("seconds", 0);
  if (workers == 0) throw std::invalid_argument("--workers must be at least 1");
  line::install_stop_handlers();

  std::vector<WorkerStats> stats(workers);
  SpinGate gate{static_cast<int>(workers)};
  const std::int64_t begin_ns = line::monotonic_ns();
  {
    std::vector<std::jthread> pool;
    pool.reserve(workers);
    for (std::size_t w = 0; w < workers; ++w) pool.emplace_back(worker, std::ref(stats[w]), std::ref(gate), 0x1000 + w);
    std::println("busy-pool: {} workers started", workers);
    std::fflush(stdout);
    const std::int64_t deadline = seconds > 0 ? begin_ns + static_cast<std::int64_t>(seconds) * 1'000'000'000 : INT64_MAX;
    while (!line::g_stop.load(std::memory_order_relaxed) && line::monotonic_ns() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds{20});
    }
    for (std::jthread& t : pool) t.request_stop();
  }  // jthreads join
  const std::int64_t end_ns = line::monotonic_ns();

  std::int64_t first = stats[0].start_ns;
  std::int64_t last = first;
  std::int64_t cpu_total = 0;
  std::uint64_t idle_workers = 0;
  nlohmann::json per_worker = nlohmann::json::array();
  for (const WorkerStats& s : stats) {
    first = std::min(first, s.start_ns);
    last = std::max(last, s.start_ns);
    cpu_total += s.cpu_ns;
    if (s.iterations == 0) ++idle_workers;
    per_worker.push_back({{"iterations", s.iterations}, {"cpu_ns", s.cpu_ns}});
  }
  nlohmann::json out;
  out["schema"] = "lowlat-pool/1";
  out["example"] = "13-where-code-runs";
  out["workers"] = workers;
  out["workers_with_no_iterations"] = idle_workers;
  out["start_skew_ns"] = last - first;
  out["wall_ns"] = end_ns - begin_ns;
  out["cpu_ns_total"] = cpu_total;
  out["per_worker"] = std::move(per_worker);
  std::println("busy-pool: stopped after {} ms; start skew {} ns; cpu {} ms in total", (end_ns - begin_ns) / 1'000'000, last - first, cpu_total / 1'000'000);
  if (const std::string path = options.text("out", ""); !path.empty()) {
    std::ofstream file{path};
    if (!(file << out.dump(2) << '\n')) throw std::runtime_error("cannot write " + path);
  }
  return EXIT_SUCCESS;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return run(lowlat::lockfree::Options{argc, argv, 1});
  } catch (const std::exception& e) {
    std::println(stderr, "busy-pool: {}", e.what());
    return EXIT_FAILURE;
  }
}
