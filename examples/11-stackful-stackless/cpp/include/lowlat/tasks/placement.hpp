// Thread placement and per-thread scheduler counters for the Ch11 measurements.
//
// Placement here is an experiment control, not isolation: pthread_setaffinity_np on our own threads
// keeps the measured threads on known, distinct physical cores. It needs no privilege and changes
// nothing on the host. The run records where the threads ran (runtime.placement) and verify.sh checks
// the pins from /proc. Adapted from example 10's placement helpers; the Gate also records the start skew.
#pragma once

#include <nlohmann/json.hpp>

#include <barrier>
#include <chrono>
#include <cstdint>
#include <expected>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace lowlat::tasks {

/// "0,2,4" -> {0, 2, 4}; an empty list or a non-number is an error message.
[[nodiscard]] std::expected<std::vector<int>, std::string> parse_cpu_list(std::string_view csv);

/// Pins the calling thread to `cpu` and confirms with sched_getcpu() that it runs there.
/// Throws std::system_error when the kernel refuses, std::runtime_error when it runs elsewhere.
void pin_current_thread(int cpu);

/// The kernel's id of the calling thread (what /proc/<pid>/task/<tid> is named by).
[[nodiscard]] std::int64_t current_tid() noexcept;

/// The calling thread's voluntary and involuntary context switches so far, from /proc/thread-self/status.
struct CtxSwitches {
  std::int64_t voluntary = 0;
  std::int64_t involuntary = 0;
};
[[nodiscard]] CtxSwitches thread_ctx_switches();

/// `runtime.placement` for `cpus`: whether they are on distinct physical cores and whether any two
/// are SMT siblings, from sysfs topology (core_id and physical_package_id).
[[nodiscard]] nlohmann::json placement_of(std::span<const int> cpus);

/// The start of a pinned run. Each of `workers` threads calls worker_ready() first: it pins itself
/// (a `cpu` of -1 skips the pin) and waits. The coordinating thread calls release(), which waits for
/// all of them, prints one "pinned pid=P tid=T cpu=C role=R" line per thread and a "placement-ready"
/// line, holds for `hold` (verify.sh checks every thread's CPU in /proc meanwhile), prints "released"
/// and lets the workers go together. Each worker stamps CLOCK_MONOTONIC the moment it leaves the gate;
/// start_skew_ns() is the spread of those stamps.
class Gate {
 public:
  Gate(std::ptrdiff_t workers, std::chrono::milliseconds hold)
      : hold_{hold}, ready_{workers + 1}, go_{workers + 1} {}

  /// Worker thread.
  void worker_ready(int cpu, std::string role);

  /// Coordinating thread; the workers' pins are verified by the time it returns.
  void release();

  /// The CPUs the workers pinned to, in the order they arrived.
  [[nodiscard]] std::vector<int> cpus() const;

  /// Latest minus earliest worker stamp after the release (0 for fewer than two workers).
  [[nodiscard]] std::int64_t start_skew_ns() const;

  /// The first pin failure, if any. A worker whose pin fails still reaches both barriers (so nobody
  /// deadlocks) and runs unpinned; the coordinator reads this after release() and discards the run.
  [[nodiscard]] std::optional<std::string> error() const;

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
  std::vector<Entry> entries_;      // guarded by mutex_
  std::vector<std::int64_t> left_;  // guarded by mutex_: monotonic ns at each worker's exit from the gate
  std::optional<std::string> error_;  // guarded by mutex_
};

}  // namespace lowlat::tasks
