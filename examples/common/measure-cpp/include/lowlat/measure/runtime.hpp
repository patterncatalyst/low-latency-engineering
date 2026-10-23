// Builders for the optional `runtime` object of a report (schema lowlat-report/1).
//
// Each function returns a JSON fragment that fits the schema; combine them into one object and
// pass it as the `runtime` argument of Recorder::report / write_report. A mean cannot be
// expressed here, and the schema rejects any key named for one.
#pragma once

#include <nlohmann/json.hpp>

#include <cstdint>
#include <map>
#include <span>
#include <string>

namespace lowlat::measure {

/// Where `hw_counters` came from.
enum class HwSource { perf, cachegrind, perfnorm };

/// `runtime.placement`: the logical CPUs the measured threads were pinned to, whether they sit on
/// distinct physical cores, and whether any two are SMT siblings.
[[nodiscard]] nlohmann::json placement(std::span<const int> cpus, bool distinct_cores, bool smt_siblings);

/// `runtime.hw_counters`: event name -> count per operation, for a region of `ops` operations.
/// Throws std::invalid_argument when `ops` is zero.
[[nodiscard]] nlohmann::json hw_counters(HwSource source, std::uint64_t ops,
                                         const std::map<std::string, double>& per_op);

/// `runtime.counters`: exact event counts (CAS failures, max retries, torn reads, ...).
[[nodiscard]] nlohmann::json counters(const std::map<std::string, std::int64_t>& counts);

}  // namespace lowlat::measure
