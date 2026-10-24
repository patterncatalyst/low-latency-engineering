#include "cgroup_probe.hpp"

#include <charconv>
#include <fstream>
#include <string>
#include <sstream>

namespace lowlat::place {

std::expected<CpuMax, std::string> parse_cpu_max(std::string_view text) {
  while (!text.empty() && (text.back() == '\n' || text.back() == ' ')) {
    text.remove_suffix(1);
  }
  const auto space = text.find(' ');
  if (space == std::string_view::npos) {
    return std::unexpected("cpu.max has no period field");
  }
  const std::string_view quota = text.substr(0, space);
  const std::string_view period = text.substr(space + 1);
  CpuMax out{.quota_us = std::nullopt, .period_us = 0};
  if (quota != "max") {
    long value = 0;
    const auto [end, ec] = std::from_chars(quota.data(), quota.data() + quota.size(), value);
    if (ec != std::errc{} || end != quota.data() + quota.size()) {
      return std::unexpected("cpu.max quota is not a number");
    }
    out.quota_us = value;
  }
  const auto [end, ec] = std::from_chars(period.data(), period.data() + period.size(), out.period_us);
  if (ec != std::errc{} || end != period.data() + period.size()) {
    return std::unexpected("cpu.max period is not a number");
  }
  return out;
}

std::expected<std::filesystem::path, std::string> own_cgroup_dir(const Paths& paths) {
  std::ifstream in(paths.proc_self_cgroup);
  if (!in) {
    return std::unexpected("cannot open " + paths.proc_self_cgroup.string());
  }
  std::string line;
  while (std::getline(in, line)) {
    if (line.starts_with("0::")) {
      // The cgroup path is absolute ("/" or "/user.slice/..."); join it below the root.
      return paths.cgroup_root / std::filesystem::path(line.substr(3)).relative_path();
    }
  }
  return std::unexpected("no cgroup v2 line (0::) in " + paths.proc_self_cgroup.string());
}

std::expected<CpuMax, std::string> read_cpu_max(const Paths& paths) {
  auto dir = own_cgroup_dir(paths);
  if (!dir) {
    return std::unexpected(dir.error());
  }
  const std::filesystem::path root = paths.cgroup_root.lexically_normal();
  std::filesystem::path start = dir->lexically_normal();
  if (!start.has_filename()) {
    start = start.parent_path();  // "root/" and "root" are the same directory
  }
  for (std::filesystem::path current = start;; current = current.parent_path()) {
    const std::filesystem::path file = current / "cpu.max";
    if (std::ifstream in(file); in) {
      std::ostringstream text;
      text << in.rdbuf();
      return parse_cpu_max(text.str());
    }
    if (current == root || current == current.parent_path()) {
      return std::unexpected("no cpu.max in " + dir->string() + " or any ancestor up to " + root.string());
    }
  }
}

}  // namespace lowlat::place
