// The line's one clock: CLOCK_MONOTONIC in integer nanoseconds.
//
// Every *_ns field on the wire (contracts/proto) is on this clock, on the
// host that runs the simulator. It is not wall time and means nothing on
// another host. std::chrono::steady_clock is CLOCK_MONOTONIC in libstdc++ and
// libc++ on Linux but the standard does not promise it, and the wire contract
// does, so the line calls clock_gettime directly.
#pragma once

#include <time.h>

#include <cstdint>

namespace lowlat::line {

[[nodiscard]] inline std::int64_t monotonic_ns() noexcept {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<std::int64_t>(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

/// Sleep until the absolute CLOCK_MONOTONIC time `deadline_ns`.
/// Returns true when the deadline was reached (or already past), false when a
/// signal interrupted the sleep, so the caller can check its stop flag and
/// call again with the same deadline: an absolute deadline needs no
/// "remaining time" bookkeeping after EINTR.
///
/// Why not std::this_thread::sleep_until: the C++ standard only requires it to
/// return once the clock reaches the time point. libstdc++ (checked in GCC 16's
/// <bits/this_thread_sleep.h>) implements it for a steady clock as one
/// *relative* nanosleep of (deadline - now), restarted on EINTR, and gives the
/// caller no way to observe the interruption. The clock read and the syscall
/// entry are then not atomic with respect to the deadline, and a stop request
/// delivered by a signal is swallowed until the full sleep completes.
/// clock_nanosleep(TIMER_ABSTIME) hands the kernel the deadline itself.
[[nodiscard]] inline bool sleep_until_ns(std::int64_t deadline_ns) noexcept {
  const timespec ts{.tv_sec = static_cast<time_t>(deadline_ns / 1'000'000'000),
                    .tv_nsec = static_cast<long>(deadline_ns % 1'000'000'000)};
  // clock_nanosleep returns the error number directly; it does not set errno.
  return clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, nullptr) == 0;
}

}  // namespace lowlat::line
