// Builders for the optional `runtime` object of a report (schema lowlat-report/1).
//
// Each function returns a JSON fragment that fits the schema; combine them into one object and
// pass it as the `runtime` argument of Recorder::report / write_report. A mean cannot be
// expressed here, and the schema rejects any key named for one.
#pragma once

#include <nlohmann/json.hpp>

#include <cstdint>
#include <map>
#include <optional>
#include <span>
#include <string>

namespace lowlat::measure {

/// Where `hw_counters` came from.
enum class HwSource { perf, cachegrind, perfnorm };
NLOHMANN_JSON_SERIALIZE_ENUM(HwSource, {{HwSource::perf, "perf"},
                                        {HwSource::cachegrind, "cachegrind"},
                                        {HwSource::perfnorm, "perfnorm"}})

/// `runtime.placement`: the logical CPUs the measured threads were pinned to, whether they sit on
/// distinct physical cores, and whether any two are SMT siblings.
[[nodiscard]] nlohmann::json placement(std::span<const int> cpus, bool distinct_cores, bool smt_siblings);

/// `runtime.hw_counters`: event name -> count per operation, for a region of `ops` operations.
/// Throws std::invalid_argument when `ops` is zero.
[[nodiscard]] nlohmann::json hw_counters(HwSource source, std::uint64_t ops,
                                         const std::map<std::string, double>& per_op);

/// Where the measured program ran.
enum class EnvKind { host, vm, container };
NLOHMANN_JSON_SERIALIZE_ENUM(EnvKind, {{EnvKind::host, "host"}, {EnvKind::vm, "vm"}, {EnvKind::container, "container"}})

/// Container network mode.
enum class NetworkMode { host, bridge, none };
NLOHMANN_JSON_SERIALIZE_ENUM(NetworkMode, {{NetworkMode::host, "host"},
                                           {NetworkMode::bridge, "bridge"},
                                           {NetworkMode::none, "none"}})

/// `runtime.environment.container`. `cpu_quota` and `cpuset` are empty when the limit is not set.
struct ContainerInfo {
  std::string runtime;       ///< container engine, e.g. "docker"
  std::string image;         ///< image reference with an exact tag (never ":latest")
  std::string image_digest;  ///< "sha256:" plus 64 hex digits
  NetworkMode network = NetworkMode::bridge;
  std::optional<std::string> cpu_quota;  ///< CPUs, e.g. "2"
  std::optional<std::string> cpuset;     ///< e.g. "2,3"
  std::string seccomp;                   ///< "default" or a profile file name; never "unconfined"
};

/// `runtime.environment.cgroup`: cgroup v2 facts read after the run. An empty field is written as null.
struct CgroupInfo {
  std::optional<std::string> cpu_max;
  std::optional<std::string> cpuset_effective;
  std::optional<std::int64_t> nr_throttled;
  std::optional<std::int64_t> throttled_usec;
};

/// `runtime.environment`. `guest_profile` (snapshot/profile, e.g. "lab-ready-r04/stock-unpinned") is
/// required by the schema for vm and container, and `container` for container: `lowlat-report check`
/// enforces both, so this builder does not.
[[nodiscard]] nlohmann::json environment(EnvKind kind, std::optional<std::string> guest_profile = std::nullopt,
                                         const std::optional<ContainerInfo>& container = std::nullopt,
                                         const std::optional<CgroupInfo>& cgroup = std::nullopt);

/// `runtime.counters`: exact event counts (CAS failures, max retries, torn reads, ...).
[[nodiscard]] nlohmann::json counters(const std::map<std::string, std::int64_t>& counts);

}  // namespace lowlat::measure
