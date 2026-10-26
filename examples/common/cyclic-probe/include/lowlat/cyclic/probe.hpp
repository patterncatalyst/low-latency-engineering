// cyclic-probe: a periodic waker that measures its own wake-up lateness.
//
// The thread sleeps until an absolute CLOCK_MONOTONIC deadline (clock_nanosleep with TIMER_ABSTIME), wakes,
// reads the clock and records "actual wake minus intended wake". The next deadline is the previous deadline
// plus the interval, never "now plus the interval", so lateness does not accumulate as drift. This is the
// method cyclictest uses, written out so the chapters can cross-check it against the tool.
//
// Failures come back as std::expected<_, std::string> (the repo's idiom for fallible probes).
#pragma once

#include <time.h>

#include <chrono>
#include <cstdint>
#include <expected>
#include <string>

#include <nlohmann/json.hpp>

#include "lowlat/measure/recorder.hpp"

namespace lowlat::cyclic {

using Result = std::expected<void, std::string>;

/// Nanoseconds on CLOCK_MONOTONIC's own scale (not a std::chrono clock: clock_nanosleep needs the clock id).
using Mono = std::chrono::nanoseconds;

struct Config {
  int cpu = -1;                          ///< pin to this CPU; -1 leaves the affinity alone
  std::chrono::nanoseconds interval{std::chrono::milliseconds{1}};
  std::chrono::nanoseconds duration{std::chrono::seconds{1}};
  int fifo_priority = 0;                 ///< 1..99 selects SCHED_FIFO; 0 stays SCHED_OTHER
  bool lock_memory = false;              ///< mlockall(MCL_CURRENT | MCL_FUTURE) before the loop
};

/// samples + missed_periods == duration / interval whenever the run completes: every period inside the window is
/// either woken for (a sample) or skipped because the wake came after the next deadline.
struct Outcome {
  std::uint64_t samples = 0;         ///< wake-ups recorded
  std::uint64_t missed_periods = 0;  ///< periods inside the window that were skipped, not slept for
};

/// The deadline after `deadline`, and how many intervals were skipped to get past `now`.
struct Advance {
  Mono deadline;
  std::uint64_t skipped;
};

/// Pure arithmetic: deadline + interval, stepping further by whole intervals while that is strictly before `now`
/// (cyclictest's rule: a wake exactly on the next deadline is not a miss). Skipped periods are counted, not
/// back-filled: a late wake records one sample, not several.
[[nodiscard]] Advance advance(Mono deadline, Mono now, std::chrono::nanoseconds interval);

/// Pure: how many of `skipped` periods (the grid points next, next+interval, ...) fall at or before `end`. Periods
/// skipped beyond the window do not count, so samples + missed_periods stays equal to duration / interval.
[[nodiscard]] std::uint64_t missed_in_window(std::uint64_t skipped, Mono first_skipped, Mono end,
                                             std::chrono::nanoseconds interval);

/// Pure: the timespec for an absolute CLOCK_MONOTONIC time.
[[nodiscard]] timespec to_timespec(Mono t);

/// Pure: rejects an interval or duration <= 0, a duration shorter than the interval, a priority outside 0..99.
[[nodiscard]] Result validate(const Config& config);

/// The system calls, each with its errno text on failure.
[[nodiscard]] Result pin_to_cpu(int cpu);       ///< sched_setaffinity for the calling thread
[[nodiscard]] Result set_fifo(int priority);    ///< sched_setscheduler(0, SCHED_FIFO, ...): needs CAP_SYS_NICE or RLIMIT_RTPRIO
[[nodiscard]] Result lock_all_memory();         ///< mlockall: needs CAP_IPC_LOCK or RLIMIT_MEMLOCK

/// Current CLOCK_MONOTONIC time. Throws std::system_error if clock_gettime fails (it cannot for this clock).
[[nodiscard]] Mono now();

/// Applies the config (mlockall, pin, FIFO, in that order), then wakes on every deadline up to start + duration,
/// recording each lateness in `recorder`. The run ends when the next deadline passes the window, so a stalled run
/// finishes on time with fewer samples (cyclictest -D does the same) instead of overrunning a lane `timeout`.
/// Setup errors and a failing clock_nanosleep come back as the error.
[[nodiscard]] std::expected<Outcome, std::string> run(const Config& config, measure::Recorder& recorder);

/// The report's `runtime` object: placement when a CPU is pinned, counters, and the environment when given.
[[nodiscard]] nlohmann::json runtime_block(const Config& config, const Outcome& outcome,
                                           const std::string& environment_kind = {},
                                           const std::string& guest_profile = {});

}  // namespace lowlat::cyclic
