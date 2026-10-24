// Ch13 wiring skeleton: read the CPU quota from cgroup v2 `cpu.max`.
#pragma once

#include <expected>
#include <filesystem>
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

// Where to look. Tests point both at a fake tree.
struct Paths {
  std::filesystem::path cgroup_root = "/sys/fs/cgroup";
  std::filesystem::path proc_self_cgroup = "/proc/self/cgroup";
};

// The process's own cgroup, from the `0::<path>` line of /proc/self/cgroup, as a directory under
// the cgroup root. Inside a container with its own cgroup namespace the path is "/" and the
// directory is the root itself.
std::expected<std::filesystem::path, std::string> own_cgroup_dir(const Paths& paths = {});

// The cpu.max that governs this process: the file in its own cgroup, or in the nearest ancestor
// that has one. An error value if none exists up to the root.
std::expected<CpuMax, std::string> read_cpu_max(const Paths& paths = {});

}  // namespace lowlat::place
