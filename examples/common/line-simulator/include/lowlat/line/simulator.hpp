// The open-loop emitter.
#pragma once

#include <atomic>
#include <cstdint>

#include "lowlat/line/config.hpp"
#include "lowlat/measure/recorder.hpp"

namespace lowlat::line {

struct RunResult {
  std::uint64_t sent = 0;         ///< Datagrams handed to the kernel.
  std::uint64_t send_errors = 0;  ///< sendto failures (counted, never waited on).
  bool interrupted = false;       ///< Stopped early by `stop`.
};

/// Emits parcel events per `cfg`, stamping each with its intended time
/// (t0 + i / rate) and recording `actual - intended` into `emit_lateness`.
///
/// Open loop: if the sender is behind schedule it sends immediately; it never
/// skips a parcel and never stretches the schedule. A send that cannot
/// complete at once (full socket buffer, nobody listening) is counted and the
/// belt moves on.
///
/// `stop` is polled between parcels; a signal handler may set it. Throws
/// std::runtime_error when the socket cannot be created or `cfg.dest` cannot
/// be resolved.
RunResult run(const Config& cfg, const std::atomic<bool>& stop, measure::Recorder& emit_lateness);

}  // namespace lowlat::line
