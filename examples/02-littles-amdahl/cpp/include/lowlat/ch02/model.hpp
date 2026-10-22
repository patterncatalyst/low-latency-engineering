// The two laws of Ch2 as code. Both are modelling tools: they take a
// time-average or a time fraction as an INPUT and predict something else.
// Neither is ever a latency result (CLAUDE.md, "Means").
#pragma once

#include <cstdint>

namespace lowlat::ch02 {

/// Amdahl's Law. `serial_fraction` s is the share of the one-worker run that
/// cannot be parallelised (here: time inside the lock). With the parallel
/// fraction p = 1 - s the speedup on n workers is
///     S(n) = 1 / ((1 - p) + p / n) = 1 / (s + (1 - s) / n)
/// and it can never exceed 1 / s.
[[nodiscard]] constexpr double amdahl_speedup(double serial_fraction, unsigned workers) noexcept {
  return 1.0 / (serial_fraction + (1.0 - serial_fraction) / static_cast<double>(workers));
}

/// Parcels whose intended emit time is at or before `now_ns`, on a line that
/// emits `rate_hz` parcels per second starting at `t0_ns` (parcel 0 is due AT
/// t0). Integer arithmetic, exact for windows up to hours at kHz rates.
[[nodiscard]] constexpr std::int64_t arrivals_by(std::int64_t now_ns, std::int64_t t0_ns,
                                                 std::int64_t rate_hz) noexcept {
  if (now_ns < t0_ns) return 0;
  return (now_ns - t0_ns) * rate_hz / 1'000'000'000 + 1;
}

/// Little's Law, L = lambda * W, with W in seconds.
[[nodiscard]] constexpr double littles_L(double lambda_per_s, double w_seconds) noexcept {
  return lambda_per_s * w_seconds;
}

}  // namespace lowlat::ch02
