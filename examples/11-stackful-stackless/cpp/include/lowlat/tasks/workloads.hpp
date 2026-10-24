// The three Ch11 micro workloads, each in three execution models:
//   os-thread  one OS thread per task (std::jthread, std::binary_semaphore)
//   fiber      Boost.Fiber on one OS thread (round_robin scheduler, 64 KiB protected stacks, buffered_channel)
//   coroutine  stackless: Asio awaitable and steady_timer; a minimal Task<T> with symmetric transfer
//              for the ping-pong and the frame probes
// See ../../README.md for what each one measures and why.
#pragma once

#include <chrono>
#include <cstdint>
#include <expected>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "lowlat/tasks/placement.hpp"

namespace lowlat::tasks {

enum class Variant { os_thread, fiber, coroutine };

[[nodiscard]] std::optional<Variant> parse_variant(std::string_view name);
[[nodiscard]] std::string_view name_of(Variant v);

/// The stack of every fiber (Boost.Context protected_fixedsize_stack: the usable size, plus a guard page).
inline constexpr std::size_t kFiberStackBytes = 64 * 1024;

/// What one workload measured.
struct Run {
  std::vector<std::int64_t> samples;            ///< nanoseconds; never empty on success
  std::map<std::string, std::int64_t> counters; ///< exact counts and memory readings (runtime.counters)
  std::vector<int> cpus;                        ///< CPUs the measured threads were pinned to (runtime.placement)
  CtxSwitches ctx;                              ///< context switches of the measured threads
  std::string notes;
};

// ---- (a) memory per waiting task ----------------------------------------------------------------------------------

struct ParkedParams {
  std::size_t tasks = 10'000;
  std::chrono::milliseconds wait{1000};
  int cpu = -1;  ///< the thread that hosts fibers or coroutines (-1: unpinned); OS-thread tasks float
  std::chrono::milliseconds hold{0};
};

/// `tasks` tasks each wait on one shared 1 s deadline. Samples: wake lateness per task. Counters: tasks
/// armed (the start handshake, must equal `tasks`), RSS before and while parked, page-table and kernel-stack
/// deltas. The coroutine variant adds the counted-frame probe (frames that escape, so they cannot be elided).
[[nodiscard]] std::expected<Run, std::string> run_parked(Variant v, const ParkedParams& p);

// ---- (b) hand-off ----------------------------------------------------------------------------------------------------

struct PingPongParams {
  std::uint64_t rounds = 1'000'000;
  std::uint64_t batch = 1'000;
  std::uint64_t warmup_batches = 20;
  std::vector<int> cpus;  ///< two for os-thread, one for fiber and coroutine; empty: unpinned
  std::chrono::milliseconds hold{0};
  std::string handoff = "condvar";  ///< os-thread only: "condvar" (always sleeps) or "semaphore" (spins first)
};

/// Two tasks pass a turn back and forth `rounds` times. Samples: batch time divided by the batch size, in ns.
[[nodiscard]] std::expected<Run, std::string> run_pingpong(Variant v, const PingPongParams& p);

// ---- (c) the blocking call ---------------------------------------------------------------------------------------

struct NeighbourParams {
  std::size_t tasks = 1000;
  std::size_t iterations = 500;
  std::chrono::microseconds period{2000};
  bool blocking_call = false;  ///< task 0 makes one blocking sleep of `block` every tenth iteration (fiber only)
  std::chrono::microseconds block{2000};
  int cpu = -1;
  std::chrono::milliseconds hold{0};
};

/// `tasks` tasks wake every `period`, staggered across it. Samples: how late each wake was, for every task.
[[nodiscard]] std::expected<Run, std::string> run_neighbours(Variant v, const NeighbourParams& p);

// ---- frame probes (coroutine) ----------------------------------------------------------------------------------

struct FrameProbe {
  std::uint64_t parked_frames = 0;       ///< coroutines created and parked on a timer, all alive at once
  std::uint64_t allocations = 0;         ///< promise operator new calls for those frames
  std::uint64_t bytes = 0;               ///< bytes requested by them
  std::uint64_t control_frames = 0;      ///< coroutines created, run and destroyed inside one loop
  std::uint64_t control_allocations = 0; ///< how many of those reached operator new (fewer means the compiler elided)
};

/// Parks `n` Task coroutines (each with a steady_timer in its frame) in a vector, so every frame escapes the
/// function that created it; then runs the control loop of `control` non-escaping coroutines.
[[nodiscard]] FrameProbe probe_frames(std::uint64_t n, std::uint64_t control);

}  // namespace lowlat::tasks
