// The C++ line consumer: UDP receive, ParcelEvent decode, per-parcel work,
// latency against the intended emit time. See ../../../../README.md.
#pragma once

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <string_view>

#include "lowlat/line/v1/parcel.pb.h"
#include "lowlat/measure/recorder.hpp"

namespace lowlat::line {

struct ConsumerConfig {
  std::string bind = "127.0.0.1:47000";   ///< host:port (IPv4).
  int rcvbuf = 4 * 1024 * 1024;           ///< SO_RCVBUF request, bytes.
  std::optional<std::uint64_t> expect;    ///< Stop after received + dropped reaches this.
  int idle_timeout_ms = 2000;             ///< Stop this long after the last datagram.
  std::optional<std::filesystem::path> report;
  std::string example = "00-line-consumer";
  std::string variant = "baseline";
};

/// Throws std::invalid_argument on an unknown option, missing value or bad value.
[[nodiscard]] ConsumerConfig parse_consumer_args(std::span<const std::string_view> args);
[[nodiscard]] std::string_view consumer_usage() noexcept;

/// Sequence accounting. Parcels are numbered from 0 without gaps, so the next
/// expected number is the highest seen plus one (0 before anything arrives).
/// A jump forward adds the skipped count to `dropped`; a number at or below
/// the highest seen is `reordered` (or duplicated) and is not counted again.
class SeqTracker {
 public:
  enum class Kind { in_order, gap, reordered };

  Kind observe(std::uint64_t seq) noexcept;

  [[nodiscard]] std::uint64_t received() const noexcept { return received_; }  ///< In order or after a gap.
  [[nodiscard]] std::uint64_t dropped() const noexcept { return dropped_; }
  [[nodiscard]] std::uint64_t reordered() const noexcept { return reordered_; }

 private:
  std::uint64_t next_ = 0;
  std::uint64_t received_ = 0;
  std::uint64_t dropped_ = 0;
  std::uint64_t reordered_ = 0;
};

inline constexpr unsigned kLanes = 8;

/// The r01 "work": decode the SSCC-18 serial reference (digits 9..17 of the
/// 18-digit code: extension, 7-digit prefix, 9-digit serial, check digit) and
/// map it to a lane, serial modulo 8. Throws std::invalid_argument for a
/// barcode that is not 18 ASCII digits.
[[nodiscard]] unsigned lane_for(std::string_view sscc);

struct ConsumerResult {
  std::uint64_t received = 0;
  std::uint64_t dropped = 0;
  std::uint64_t reordered = 0;
  std::uint64_t malformed = 0;
  int granted_rcvbuf = 0;  ///< What getsockopt(SO_RCVBUF) reports (Linux doubles the request).
  std::string stopped_by;  ///< "expect", "idle", "signal".
  std::uint64_t lane_counts[kLanes]{};
};

/// Called once the socket is bound and sized, before the first receive:
/// `granted_rcvbuf` is what getsockopt(SO_RCVBUF) reports (Linux doubles the
/// request and caps it at net.core.rmem_max); `port` is the bound port.
using ReadyFn = std::function<void(int port, int granted_rcvbuf)>;

/// Binds, receives until a stop condition, records into `latency` (and
/// add_dropped). Throws std::runtime_error on socket errors or, for a clock
/// bug, when a latency is negative. `stop` may be set from a signal handler.
ConsumerResult consume(const ConsumerConfig& cfg, const std::atomic<bool>& stop, measure::Recorder& latency,
                       const ReadyFn& on_ready = {});

/// Free-text `notes` for the report.
[[nodiscard]] std::string notes_for(const ConsumerResult& r, const ConsumerConfig& cfg);

}  // namespace lowlat::line
