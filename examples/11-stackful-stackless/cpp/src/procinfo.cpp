#include "lowlat/tasks/procinfo.hpp"

#include <charconv>
#include <fstream>
#include <string>

namespace lowlat::tasks {

std::optional<std::int64_t> proc_kib(std::string_view file, std::string_view key) {
  std::ifstream in{std::string{file}};
  if (!in) return std::nullopt;
  const std::string prefix = std::string{key} + ":";
  for (std::string line; std::getline(in, line);) {
    if (!line.starts_with(prefix)) continue;
    std::size_t at = prefix.size();
    while (at < line.size() && (line[at] == ' ' || line[at] == '\t')) ++at;
    std::int64_t v = 0;
    const auto [end, ec] = std::from_chars(line.data() + at, line.data() + line.size(), v);
    if (ec != std::errc{}) return std::nullopt;
    return v;
  }
  return std::nullopt;
}

MemorySnapshot memory_snapshot() {
  return {proc_kib("/proc/self/status", "VmRSS").value_or(0), proc_kib("/proc/self/status", "VmSize").value_or(0), proc_kib("/proc/self/status", "VmPTE").value_or(0),
          proc_kib("/proc/meminfo", "KernelStack").value_or(0)};
}

}  // namespace lowlat::tasks
