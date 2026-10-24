#include "cgroup_probe.hpp"

#include <charconv>
#include <fstream>
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

std::expected<CpuMax, std::string> read_cpu_max(const char* path) {
  std::ifstream in(path);
  if (!in) {
    return std::unexpected(std::string("cannot open ") + path);
  }
  std::ostringstream text;
  text << in.rdbuf();
  return parse_cpu_max(text.str());
}

}  // namespace lowlat::place
