// C++ measurement kit: the Recorder API of examples/common/MEASUREMENT.md.
//
// Latencies are int64_t nanoseconds in an HdrHistogram (1 ns .. 1 h, 3
// significant digits), the same parameters as the Python and Java kits so the
// encoded histograms are interchangeable. Percentiles come from the library,
// never from hand-rolled code, and no mean is ever computed.
//
// Errors are reported with exceptions (std::runtime_error family), throughout.
// A Recorder is not thread-safe: use one per recording thread.
#pragma once

#include <hdr/hdr_histogram.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <string_view>

namespace lowlat::measure {

inline constexpr std::int64_t kLowestTrackableNs = 1;
inline constexpr std::int64_t kHighestTrackableNs = 3'600'000'000'000;  // one hour
inline constexpr int kSignificantDigits = 3;

/// RAII owner of an hdr_histogram; hdr_close runs on destruction.
using Histogram = std::unique_ptr<hdr_histogram, decltype(&hdr_close)>;

/// An empty histogram with the kit's fixed parameters.
[[nodiscard]] Histogram make_histogram();

/// Decode the base64 compressed-V2 form (the `hdr_histogram` report field).
/// Throws std::runtime_error when the string is not a valid histogram.
[[nodiscard]] Histogram decode(std::string_view base64);

/// The JSON document named by $LOWLAT_PROFILE (written by scripts/profile.sh
/// --out). Throws std::runtime_error with a clear message when the variable is
/// unset or the file is unreadable: a number without a profile is not publishable.
[[nodiscard]] nlohmann::json load_profile();

class Recorder {
 public:
  /// `example` is e.g. "03-coordinated-omission", `variant` e.g. "intended-time".
  Recorder(std::string example, std::string variant);

  /// Plain record. Throws std::out_of_range if outside [0, 1 h].
  void record(std::int64_t latency_ns);
  void record(std::chrono::nanoseconds latency) { record(latency.count()); }

  /// Record with coordinated-omission back-fill (hdr_record_corrected_value):
  /// if latency exceeds the expected interval, the samples a well-behaved
  /// sender would have produced during the stall are added as well.
  void record_corrected(std::int64_t latency_ns, std::int64_t expected_interval_ns);
  void record_corrected(std::chrono::nanoseconds latency, std::chrono::nanoseconds expected_interval) {
    record_corrected(latency.count(), expected_interval.count());
  }

  /// Parcels that never arrived (sequence gaps).
  void add_dropped(std::uint64_t n) noexcept { dropped_ += n; }

  [[nodiscard]] std::int64_t count() const noexcept { return hdr_total_count(hist_.get()); }
  [[nodiscard]] std::uint64_t dropped() const noexcept { return dropped_; }
  [[nodiscard]] const hdr_histogram& histogram() const noexcept { return *hist_; }

  /// The report document (schema lowlat-report/1). Throws if LOWLAT_PROFILE is unset.
  /// `notes` is free text for the optional `notes` field, written only when non-empty.
  /// `model` is the optional `model` object (the only place a time-average may appear);
  /// it is written only when it holds a non-empty JSON object.
  [[nodiscard]] nlohmann::json report(std::string_view notes = {},
                                      const std::optional<nlohmann::json>& model = std::nullopt) const;

  /// Writes report(notes, model) to `path` and returns it.
  nlohmann::json write_report(const std::filesystem::path& path, std::string_view notes = {},
                              const std::optional<nlohmann::json>& model = std::nullopt) const;

  /// One aligned line: example, language, variant, count, dropped, p50, p90,
  /// p99, p99.9, max in microseconds (1 decimal). Never a mean.
  [[nodiscard]] std::string summary_line() const;
  void print_summary() const;

 private:
  std::string example_;
  std::string variant_;
  Histogram hist_;
  std::uint64_t dropped_ = 0;
};

}  // namespace lowlat::measure
