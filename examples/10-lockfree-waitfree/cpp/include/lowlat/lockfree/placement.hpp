// Thread placement and per-thread scheduler counters for the Ch10 measurements.
//
// Placement here is an experiment control, not isolation: pthread_setaffinity_np on our own threads
// keeps the claim, litmus and seqlock threads on known, distinct physical cores. It needs no
// privilege and changes nothing on the host. The run records where the threads ran
// (runtime.placement) and a script checks the pins from /proc.
#pragma once

#include <nlohmann/json.hpp>

#include <barrier>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace lowlat::lockfree {

/// "0,2,4" -> {0, 2, 4}. Throws std::invalid_argument on an empty list or a non-number.
[[nodiscard]] std::vector<int> parse_cpu_list(std::string_view csv);

/// Pins the calling thread to `cpu` and confirms with sched_getcpu() that it runs there.
/// Throws std::system_error when the kernel refuses, std::runtime_error when it runs elsewhere.
void pin_current_thread(int cpu);

/// The kernel's id of the calling thread (what /proc/<pid>/task/<tid> is named by).
[[nodiscard]] std::int64_t current_tid() noexcept;

/// The thread's voluntary and involuntary context switches so far, from /proc/thread-self/status.
struct CtxSwitches {
  std::int64_t voluntary = 0;
  std::int64_t involuntary = 0;
};
[[nodiscard]] CtxSwitches thread_ctx_switches();

/// `runtime.placement` for `cpus`: whether they are on distinct physical cores and whether any two
/// are SMT siblings, from sysfs topology (core_id and physical_package_id).
[[nodiscard]] nlohmann::json placement_of(std::span<const int> cpus);

/// The start of a pinned run. Each of `workers` threads calls worker_ready() first: it pins itself
/// and waits. The coordinating thread calls release(), which waits for all of them, prints one
/// "pinned pid=P tid=T cpu=C role=R" line per thread and a "placement-ready" line, holds for `hold`
/// (a script checks every thread's CPU in /proc meanwhile) and lets the workers go together.
class Gate {
 public:
  Gate(std::ptrdiff_t workers, std::chrono::milliseconds hold)
      : hold_{hold}, ready_{workers + 1}, go_{workers + 1} {}

  /// Worker thread. A `cpu` of -1 skips the pin (unit tests).
  void worker_ready(int cpu, std::string role);

  /// Coordinating thread; the workers' pins are verified by the time it returns.
  void release();

  /// The CPUs the workers pinned to, in the order they arrived.
  [[nodiscard]] std::vector<int> cpus() const;

 private:
  struct Entry {
    std::int64_t tid;
    int cpu;
    std::string role;
  };
  std::chrono::milliseconds hold_;
  std::barrier<> ready_;
  std::barrier<> go_;
  mutable std::mutex mutex_;
  std::vector<Entry> entries_;  // guarded by mutex_
};

}  // namespace lowlat::lockfree
