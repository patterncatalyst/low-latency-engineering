// Ch13 wiring skeleton: read the CPU quota from cgroup v2 `cpu.max`.
#pragma once

#include <expected>
#include <optional>
#include <string>
#include <string_view>

namespace lowlat::place {

struct CpuMax {
  std::optional<long> quota_us;  // nullopt for "max" (no quota)
  long period_us;
};

// Parses the text of cpu.max: "max 100000" or "200000 100000".
std::expected<CpuMax, std::string> parse_cpu_max(std::string_view text);

// Reads and parses `path` (default /sys/fs/cgroup/cpu.max).
std::expected<CpuMax, std::string> read_cpu_max(const char* path = "/sys/fs/cgroup/cpu.max");

}  // namespace lowlat::place
