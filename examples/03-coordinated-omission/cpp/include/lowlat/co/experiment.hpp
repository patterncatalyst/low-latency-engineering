// Ch3: one stall, three ways of measuring it. See ../../../../README.md.
//
// A consumer of the line simulator injects ONE blocking stall and records the
// same run with the clock started at three different places:
//   receipt-time           done - time the datagram was dequeued (naive)
//   intended-time          done - intended_emit_ns, the belt's schedule (honest)
// and a separate closed-loop client, recorded two ways:
//   closed-loop-naive      one sample per request
//   closed-loop-corrected  the same samples through record_corrected(1 ms)
#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <span>
#include <string>
#include <string_view>

#include "lowlat/measure/recorder.hpp"

namespace lowlat::co {

inline constexpr std::string_view kExample = "03-coordinated-omission";
inline constexpr std::chrono::nanoseconds kExpectedInterval = std::chrono::milliseconds{1};

struct Config {
  std::string bind = "127.0.0.1:47230";
  int rcvbuf = 4 * 1024 * 1024;
  std::uint64_t expect = 10'000;  ///< parcels (received + dropped) before the UDP phase ends
  int idle_timeout_ms = 2000;
  std::int64_t stall_ms = 200;    ///< 0 = control run, no stall
  std::uint64_t stall_seq = 5000; ///< parcel (and closed-loop request) that stalls
  std::string suffix;             ///< appended to every variant, e.g. "-control"
  std::filesystem::path out_dir = ".";
};

/// Throws std::invalid_argument on a bad command line. `args` excludes the subcommand.
[[nodiscard]] Config parse_args(std::span<const std::string_view> args);

/// The four recorders of one run. Variant names carry the suffix.
struct Recorders {
  explicit Recorders(const std::string& suffix);
  measure::Recorder receipt_time;
  measure::Recorder intended_time;
  measure::Recorder closed_loop_corrected;
  measure::Recorder closed_loop_naive;
};

/// The stall: a blocking sleep, which models a GC pause, a page fault or a lock
/// convoy. It is the one place in the example where sleeping is the right tool.
void stall_for(std::chrono::milliseconds d);

/// Receive `cfg.expect` parcels from the simulator. Records receipt-time and
/// intended-time. Returns the number of parcels that never arrived.
std::uint64_t run_receive(const Config& cfg, Recorders& rec);

/// `requests` closed-loop requests, one per kExpectedInterval: each starts, handles one
/// parcel, finishes, and only then is the next one issued. Request `cfg.stall_seq`
/// stalls. Each latency goes in plain (naive) and through record_corrected.
void run_closed_loop(const Config& cfg, std::uint64_t requests, Recorders& rec);

/// Cost of one clock read over `calls` back-to-back reads of two clocks.
struct ClockProbe {
  measure::Recorder line_monotonic_ns{std::string{kExample}, "clock-read"};
  measure::Recorder steady_clock{std::string{kExample}, "clock-read-steady_clock"};
};
void run_clock_probe(std::uint64_t calls, ClockProbe& probe);

}  // namespace lowlat::co
