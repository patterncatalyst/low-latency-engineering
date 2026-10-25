// Placement facts for one thread: the CPU it last ran on, the CPUs it may run on, and its context switches.
#pragma once

#include <chrono>
#include <cstdint>
#include <expected>
#include <string>
#include <string_view>
#include <vector>

#include <nlohmann/json.hpp>

namespace lowlat::placement {

struct Switches {
  std::int64_t voluntary = 0;    ///< blocked or yielded (getrusage ru_nvcsw)
  std::int64_t involuntary = 0;  ///< preempted (getrusage ru_nivcsw)
};

/// "2-3,7" for {2,3,7}: the kernel's cpulist form. Pure.
[[nodiscard]] std::string format_cpu_list(const std::vector<int>& cpus);

/// The CPUs in the calling thread's affinity mask, ascending.
[[nodiscard]] std::expected<std::vector<int>, std::string> affinity_cpus();

/// The CPU the calling thread is running on now (sched_getcpu).
[[nodiscard]] std::expected<int, std::string> current_cpu();

/// Context-switch counts of the calling thread only (RUSAGE_THREAD), so other threads' switches are not mixed in.
[[nodiscard]] std::expected<Switches, std::string> thread_switches();

/// Pins to `cpu` when it is >= 0, spins for `busy` on the calling thread, and reports the lowlat-placement-probe/1 JSON:
/// start and end CPU, the affinity list, and the switch counts accrued during the spin.
[[nodiscard]] std::expected<nlohmann::json, std::string> probe(int cpu, std::chrono::milliseconds busy);

}  // namespace lowlat::placement
