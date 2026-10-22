// The open-loop schedule: when parcel i *should* be emitted and where the belt
// is at that moment. Pure arithmetic, no clock, so it is exactly testable.
#pragma once

#include <cmath>
#include <cstdint>

namespace lowlat::line {

struct Schedule {
  std::int64_t t0_ns;       ///< CLOCK_MONOTONIC time of parcel 0.
  std::uint32_t rate_hz;    ///< Parcels per second; > 0.

  /// t0 + i / rate, in integer nanoseconds (floor). The schedule is a pure
  /// function of i: it can never drift, whatever the sender did before.
  [[nodiscard]] constexpr std::int64_t intended_ns(std::uint64_t i) const noexcept {
    return t0_ns + static_cast<std::int64_t>(i * 1'000'000'000ULL / rate_hz);
  }
};

/// Belt position at `elapsed_ns` after the line started, in encoder ticks:
/// floor(elapsed seconds x belt speed m/s x pulses per metre).
[[nodiscard]] inline std::uint64_t encoder_tick(std::int64_t elapsed_ns, double belt_speed_mps,
                                                double pulses_per_metre) noexcept {
  const double ticks = static_cast<double>(elapsed_ns) * 1e-9 * belt_speed_mps * pulses_per_metre;
  return static_cast<std::uint64_t>(std::floor(ticks));
}

/// The physical scan-to-divert budget: distance / belt speed, in milliseconds.
[[nodiscard]] constexpr double scan_to_divert_ms(double distance_m, double belt_speed_mps) noexcept {
  return distance_m / belt_speed_mps * 1e3;
}

}  // namespace lowlat::line
