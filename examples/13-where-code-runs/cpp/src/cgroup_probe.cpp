#include "cgroup_probe.hpp"

#include <fcntl.h>
#include <linux/io_uring.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <charconv>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

namespace lowlat::place {

namespace {

namespace fs = std::filesystem;

std::string trim(std::string_view text) {
  while (!text.empty() && (text.back() == '\n' || text.back() == ' ' || text.back() == '\r')) text.remove_suffix(1);
  while (!text.empty() && text.front() == ' ') text.remove_prefix(1);
  return std::string{text};
}

template <typename T>
bool parse_number(std::string_view text, T& out) {
  const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), out);
  return ec == std::errc{} && end == text.data() + text.size();
}

std::expected<std::string, std::string> slurp(const fs::path& file) {
  std::ifstream in(file);
  if (!in) return std::unexpected("cannot open " + file.string());
  std::ostringstream text;
  text << in.rdbuf();
  return text.str();
}

// The file `name` in the own cgroup, or in the nearest ancestor that has it, up to the root.
std::expected<std::string, std::string> read_inherited(const Paths& paths, std::string_view name) {
  auto dir = own_cgroup_dir(paths);
  if (!dir) return std::unexpected(dir.error());
  const fs::path root = paths.cgroup_root.lexically_normal();
  fs::path start = dir->lexically_normal();
  if (!start.has_filename()) start = start.parent_path();  // "root/" and "root" are the same directory
  for (fs::path current = start;; current = current.parent_path()) {
    if (std::ifstream in(current / std::string{name}); in) {
      std::ostringstream text;
      text << in.rdbuf();
      return text.str();
    }
    if (current == root || current == current.parent_path()) {
      return std::unexpected("no " + std::string{name} + " in " + dir->string() + " or any ancestor up to " + root.string());
    }
  }
}

}  // namespace

std::expected<CpuMax, std::string> parse_cpu_max(std::string_view text) {
  while (!text.empty() && (text.back() == '\n' || text.back() == ' ')) text.remove_suffix(1);
  const auto space = text.find(' ');
  if (space == std::string_view::npos) return std::unexpected("cpu.max has no period field");
  const std::string_view quota = text.substr(0, space);
  const std::string_view period = text.substr(space + 1);
  CpuMax out{.quota_us = std::nullopt, .period_us = 0};
  if (quota != "max") {
    long value = 0;
    if (!parse_number(quota, value)) return std::unexpected("cpu.max quota is not a number");
    out.quota_us = value;
  }
  if (!parse_number(period, out.period_us) || out.period_us <= 0) return std::unexpected("cpu.max period is not a positive number");
  return out;
}

std::optional<long> quota_cpus(const CpuMax& max) {
  if (!max.quota_us || max.period_us <= 0) return std::nullopt;
  return (*max.quota_us + max.period_us - 1) / max.period_us;
}

std::optional<std::uint64_t> CpuStat::get(std::string_view key) const {
  const auto it = values.find(key);
  if (it == values.end()) return std::nullopt;
  return it->second;
}

std::expected<CpuStat, std::string> parse_cpu_stat(std::string_view text) {
  CpuStat stat;
  std::istringstream in{std::string{text}};
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    const auto space = line.find(' ');
    if (space == std::string::npos) return std::unexpected("cpu.stat line without a value: " + line);
    std::uint64_t value = 0;
    if (!parse_number(std::string_view{line}.substr(space + 1), value)) return std::unexpected("cpu.stat value is not a number: " + line);
    stat.values[line.substr(0, space)] = value;
  }
  if (stat.values.empty()) return std::unexpected("cpu.stat is empty");
  return stat;
}

std::expected<std::size_t, std::string> count_cpus(std::string_view list) {
  const std::string text = trim(list);
  if (text.empty()) return std::unexpected("empty CPU list");
  std::size_t total = 0;
  std::istringstream in{text};
  std::string part;
  while (std::getline(in, part, ',')) {
    const auto dash = part.find('-');
    long lo = 0;
    long hi = 0;
    if (dash == std::string::npos) {
      if (!parse_number(part, lo)) return std::unexpected("bad CPU list entry '" + part + "'");
      hi = lo;
    } else if (!parse_number(std::string_view{part}.substr(0, dash), lo) || !parse_number(std::string_view{part}.substr(dash + 1), hi) || hi < lo) {
      return std::unexpected("bad CPU range '" + part + "'");
    }
    total += static_cast<std::size_t>(hi - lo + 1);
  }
  return total;
}

std::expected<fs::path, std::string> own_cgroup_dir(const Paths& paths) {
  std::ifstream in(paths.proc_self_cgroup);
  if (!in) return std::unexpected("cannot open " + paths.proc_self_cgroup.string());
  std::string line;
  while (std::getline(in, line)) {
    if (line.starts_with("0::")) {
      // The cgroup path is absolute ("/" or "/user.slice/..."); join it below the root.
      return paths.cgroup_root / fs::path(line.substr(3)).relative_path();
    }
  }
  return std::unexpected("no cgroup v2 line (0::) in " + paths.proc_self_cgroup.string());
}

std::expected<CpuMax, std::string> read_cpu_max(const Paths& paths) {
  auto text = read_inherited(paths, "cpu.max");
  if (!text) return std::unexpected(text.error());
  return parse_cpu_max(*text);
}

std::expected<std::string, std::string> read_cpuset_effective(const Paths& paths) {
  auto text = read_inherited(paths, "cpuset.cpus.effective");
  if (!text) return std::unexpected(text.error());
  return trim(*text);
}

std::expected<CpuStat, std::string> read_cpu_stat(const Paths& paths) {
  auto dir = own_cgroup_dir(paths);
  if (!dir) return std::unexpected(dir.error());
  auto text = slurp(*dir / "cpu.stat");
  if (!text) return std::unexpected(text.error());
  return parse_cpu_stat(*text);
}

std::expected<std::string, std::string> read_online_cpus(const Paths& paths) {
  auto text = slurp(paths.online_cpus);
  if (!text) return std::unexpected(text.error());
  return trim(*text);
}

int io_uring_setup_errno() noexcept {
  io_uring_params params{};
  const long fd = ::syscall(SYS_io_uring_setup, 8U, &params);
  if (fd < 0) return errno;
  ::close(static_cast<int>(fd));
  return 0;
}

std::string errno_name(int err) {
  switch (err) {
    case 0: return "ok";
    case EPERM: return "EPERM";
    case ENOSYS: return "ENOSYS";
    case ENOMEM: return "ENOMEM";
    case EINVAL: return "EINVAL";
    case EACCES: return "EACCES";
    default: return std::strerror(err);
  }
}

}  // namespace lowlat::place
