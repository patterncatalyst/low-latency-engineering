// cyclic-probe [--cpu N] [--interval-us N] [--duration-ms N] [--priority 1..99] [--mlockall]
//              [--example NAME] [--variant NAME] [--env host|vm|container] [--guest-profile SNAPSHOT/PROFILE]
//              [--report FILE]
//
// Wakes on an absolute CLOCK_MONOTONIC deadline and records wake lateness. With --report it writes a
// lowlat-report/1 document (needs LOWLAT_PROFILE, as every report does).
#include <charconv>
#include <chrono>
#include <cstdlib>
#include <exception>
#include <format>
#include <map>
#include <print>
#include <stdexcept>
#include <string>
#include <string_view>

#include "lowlat/cyclic/probe.hpp"

namespace {

using namespace lowlat;

std::int64_t number(std::string_view option, const std::string& text) {
  std::int64_t value = 0;
  const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), value);
  if (ec != std::errc{} || end != text.data() + text.size()) {
    throw std::invalid_argument(std::format("--{}: '{}' is not a number", option, text));
  }
  return value;
}

int run(int argc, char** argv) {
  std::map<std::string, std::string, std::less<>> opts;
  for (int i = 1; i < argc; ++i) {
    std::string_view key{argv[i]};
    if (!key.starts_with("--")) throw std::invalid_argument(std::format("unexpected argument '{}'", key));
    key.remove_prefix(2);
    if (key == "mlockall") {
      opts["mlockall"] = "1";
    } else if (i + 1 < argc) {
      opts[std::string{key}] = argv[++i];
    } else {
      throw std::invalid_argument(std::format("--{} needs a value", key));
    }
  }
  const auto get = [&opts](std::string_view key, std::string fallback) {
    const auto it = opts.find(key);
    return it == opts.end() ? fallback : it->second;
  };

  cyclic::Config config;
  config.cpu = static_cast<int>(number("cpu", get("cpu", "-1")));
  config.interval = std::chrono::microseconds{number("interval-us", get("interval-us", "1000"))};
  config.duration = std::chrono::milliseconds{number("duration-ms", get("duration-ms", "1000"))};
  config.fifo_priority = static_cast<int>(number("priority", get("priority", "0")));
  config.lock_memory = opts.contains("mlockall");

  measure::Recorder recorder{get("example", "16-cyclictest"), get("variant", "probe")};
  const auto outcome = cyclic::run(config, recorder);
  if (!outcome) {
    std::println(stderr, "cyclic-probe: {}", outcome.error());
    return EXIT_FAILURE;
  }
  recorder.print_summary();
  std::println("samples={} missed_periods={}", outcome->samples, outcome->missed_periods);

  if (const std::string path = get("report", ""); !path.empty()) {
    const auto notes = std::format("clock=CLOCK_MONOTONIC abs-timer interval_us={} priority={} mlockall={}",
                                   std::chrono::duration_cast<std::chrono::microseconds>(config.interval).count(),
                                   config.fifo_priority, config.lock_memory);
    recorder.write_report(path, notes, std::nullopt,
                          cyclic::runtime_block(config, *outcome, get("env", ""), get("guest-profile", "")));
    std::println("report: {}", path);
  }
  return EXIT_SUCCESS;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return run(argc, argv);
  } catch (const std::exception& e) {
    std::println(stderr, "cyclic-probe: {}", e.what());
    return EXIT_FAILURE;
  }
}
