// pi-demo --variant plain-mutex|pi-mutex [--cpu N] [--bursts N] [--burst-ms N] [--no-rt] [--report FILE]
//
// Priority inversion on one CPU, three SCHED_FIFO threads:
//   low  (priority 10) takes the lock and holds it for 1 ms;
//   medium (priority 50) spins for --burst-ms, --bursts times, and never needs the lock;
//   high (priority 90) asks for the lock and records how long it waited.
// With a plain mutex the medium thread preempts the low holder, so high waits behind work it does not
// share a lock with. With PTHREAD_PRIO_INHERIT the holder runs at high's priority while high waits.
// --no-rt keeps every thread SCHED_OTHER (a wiring smoke run that needs no privilege and shows no inversion).
// Run it under `timeout -s KILL` in a lane: a FIFO spinner on the only CPU can starve the shell.
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <exception>
#include <format>
#include <latch>
#include <map>
#include <mutex>
#include <print>
#include <stdexcept>
#include <string>
#include <thread>

#include "lowlat/cyclic/probe.hpp"
#include "pi_mutex.hpp"

namespace {

using namespace lowlat;
using Clock = std::chrono::steady_clock;

struct Params {
  int cpu = 0;
  int bursts = 5;
  std::chrono::milliseconds burst{20};
  bool rt = true;
};

// Starts a thread at `priority` on the demo CPU. Every thread passes the `ready` barrier whether or not its setup
// worked, so a failure (no privilege for FIFO, say) stops all three instead of leaving the others waiting for a lock
// that will never be taken.
template <typename Body>
std::jthread start(const Params& p, int priority, std::latch& ready, std::atomic<bool>& failed, std::string& failure,
                   Body body) {
  return std::jthread{[&p, priority, &ready, &failed, &failure, body = std::move(body)] {
    auto ok = cyclic::pin_to_cpu(p.cpu);
    if (ok && p.rt) ok = cyclic::set_fifo(priority);
    if (!ok) {
      failure = ok.error();
      failed = true;
    }
    ready.arrive_and_wait();
    if (!failed) body();
  }};
}

template <typename Lock>
int demo(const Params& p, measure::Recorder& waits) {
  Lock lock;
  std::latch holding{1};
  std::latch ready{3};
  std::atomic<bool> failed{false};
  std::atomic<bool> done{false};
  std::string low_failure, medium_failure, high_failure;
  {
    auto low = start(p, 10, ready, failed, low_failure, [&] {
      std::lock_guard guard{lock};
      holding.count_down();
      for (const auto end = Clock::now() + std::chrono::milliseconds{1}; Clock::now() < end;) {
      }  // busy: the holder works inside the critical section
    });
    auto medium = start(p, 50, ready, failed, medium_failure, [&] {
      holding.wait();
      for (int i = 0; i < p.bursts; ++i) {
        for (const auto end = Clock::now() + p.burst; Clock::now() < end;) {
        }  // the spin that starves the holder
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      }
    });
    auto high = start(p, 90, ready, failed, high_failure, [&] {
      holding.wait();
      const auto asked = Clock::now();
      std::lock_guard guard{lock};
      waits.record(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - asked));
      done = true;
    });
  }
  for (const auto* failure : {&low_failure, &medium_failure, &high_failure}) {
    if (!failure->empty()) throw std::runtime_error(*failure);
  }
  return done ? EXIT_SUCCESS : EXIT_FAILURE;
}

int run(int argc, char** argv) {
  std::map<std::string, std::string> opts;
  for (int i = 1; i < argc; ++i) {
    const std::string key{argv[i]};
    if (!key.starts_with("--")) throw std::invalid_argument(std::format("unexpected argument '{}'", key));
    if (key == "--no-rt") {
      opts[key] = "1";
    } else if (i + 1 < argc) {
      opts[key] = argv[++i];
    } else {
      throw std::invalid_argument(std::format("{} needs a value", key));
    }
  }
  const auto get = [&opts](const std::string& key, const std::string& fallback) {
    const auto it = opts.find(key);
    return it == opts.end() ? fallback : it->second;
  };
  const std::string variant = get("--variant", "pi-mutex");
  if (variant != "plain-mutex" && variant != "pi-mutex") throw std::invalid_argument("--variant: plain-mutex | pi-mutex");

  Params p;
  p.cpu = std::stoi(get("--cpu", "0"));
  p.bursts = std::stoi(get("--bursts", "5"));
  p.burst = std::chrono::milliseconds{std::stoi(get("--burst-ms", "20"))};
  p.rt = !opts.contains("--no-rt");

  measure::Recorder waits{"14-preempt-rt", variant};
  // plain-mutex is std::mutex on purpose: it is the lock a C++ programmer reaches for, and it has no PI.
  const int rc = variant == "pi-mutex" ? demo<pi::PiMutex>(p, waits) : demo<std::mutex>(p, waits);
  std::println("variant={} rt={} high-priority waits recorded={}", variant, p.rt, waits.count());
  if (const std::string path = get("--report", ""); !path.empty()) {
    waits.write_report(path, std::format("priority inversion: low=10 medium=50 high=90 bursts={} burst_ms={} rt={}",
                                         p.bursts, p.burst.count(), p.rt));
    std::println("report: {}", path);
  }
  return rc;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return run(argc, argv);
  } catch (const std::exception& e) {
    std::println(stderr, "pi-demo: {}", e.what());
    return EXIT_FAILURE;
  }
}
