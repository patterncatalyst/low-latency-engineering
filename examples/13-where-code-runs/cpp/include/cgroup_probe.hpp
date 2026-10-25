// Ch13: what this process is allowed to use, read from its own cgroup (v2) and from the kernel.
//
// Adapted from the cgroup probe of the companion project cpp-concurrency-and-parallelism (Ch32),
// moved up to C++23: every read returns std::expected with the reason in the error value, so a
// missing file or a malformed line is a value the caller reports, not an exception.
#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>

namespace lowlat::place {

struct CpuMax {
  std::optional<long> quota_us;  // nullopt for "max" (no quota)
  long period_us;
};

// Parses the text of cpu.max: "max 100000" or "200000 100000".
std::expected<CpuMax, std::string> parse_cpu_max(std::string_view text);

// The CPUs a quota allows, rounded up the way a JVM does it: ceil(quota / period). nullopt for "max".
std::optional<long> quota_cpus(const CpuMax& max);

// cpu.stat: "key value" lines. Throttling counters (nr_periods, nr_throttled, throttled_usec) are
// present only in a cgroup with the cpu controller enabled.
struct CpuStat {
  std::map<std::string, std::uint64_t, std::less<>> values;
  [[nodiscard]] std::optional<std::uint64_t> get(std::string_view key) const;
};
std::expected<CpuStat, std::string> parse_cpu_stat(std::string_view text);

// How many CPUs a kernel CPU list names: "2-3" is 2, "0-3,8" is 5, "" is an error.
std::expected<std::size_t, std::string> count_cpus(std::string_view list);

// Where to look. Tests point these at a fake tree.
struct Paths {
  std::filesystem::path cgroup_root = "/sys/fs/cgroup";
  std::filesystem::path proc_self_cgroup = "/proc/self/cgroup";
  std::filesystem::path online_cpus = "/sys/devices/system/cpu/online";
};

// The process's own cgroup, from the `0::<path>` line of /proc/self/cgroup, as a directory under
// the cgroup root. Inside a container with its own cgroup namespace the path is "/" and the
// directory is the root itself.
std::expected<std::filesystem::path, std::string> own_cgroup_dir(const Paths& paths = {});

// The cpu.max that governs this process: the file in its own cgroup, or in the nearest ancestor
// that has one. An error value if none exists up to the root.
std::expected<CpuMax, std::string> read_cpu_max(const Paths& paths = {});

// cpuset.cpus.effective of the own cgroup, or of the nearest ancestor that has one (the file is
// absent where the cpuset controller is not enabled). Trailing newline removed.
std::expected<std::string, std::string> read_cpuset_effective(const Paths& paths = {});

// cpu.stat of the own cgroup (the counters belong to one cgroup, so no ancestor is consulted).
std::expected<CpuStat, std::string> read_cpu_stat(const Paths& paths = {});

// /sys/devices/system/cpu/online: the CPUs the kernel has online. This is what glibc's get_nprocs()
// reads, and so what std::thread::hardware_concurrency() reports, in or out of a container: the
// file is not namespaced.
std::expected<std::string, std::string> read_online_cpus(const Paths& paths = {});

// io_uring_setup(8, ...) through the raw system call: a default (zero) error_code when it works, else the errno in the
// generic category (EPERM under
// Docker's default seccomp profile, ENOSYS or EPERM when the kernel disables it). The raw call is
// the point: liburing would report the same errno through one more layer, and this probe must link
// nothing that could change what the kernel or a seccomp filter answers.
std::error_code io_uring_setup_error() noexcept;

// "ok" for 0, else the symbolic name of the errno the probe can meet, else strerror.
std::string errno_name(int err);

}  // namespace lowlat::place
