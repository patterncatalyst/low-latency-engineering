// Thread placement as an experiment control: pin the calling thread to one logical CPU with
// pthread_setaffinity_np and report which thread it is, so verify.sh can check /proc/<pid>/task/<tid>.
// Unprivileged and confined to our own threads; it is not isolation (the scheduler still shares the
// CPU with whatever else the host runs).
#pragma once

#include <pthread.h>
#include <sched.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <print>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace lowlat::eliminating {

/// Pins the calling thread to `cpu`. Throws std::system_error when the kernel refuses.
inline void pin_current_thread(int cpu) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  if (const int rc = pthread_setaffinity_np(pthread_self(), sizeof(set), &set); rc != 0) {
    throw std::system_error(rc, std::generic_category(), "pthread_setaffinity_np(cpu " + std::to_string(cpu) + ")");
  }
}

[[nodiscard]] inline pid_t current_tid() noexcept { return ::gettid(); }

/// Prints "placement pid= tid= cpu= role=" for the calling thread. verify.sh reads these lines to check
/// /proc/<pid>/task/<tid>/stat while the threads hold; when LOWLAT_PLACEMENT_FILE is set the line is appended
/// to that file as well, because `perf stat` holds back the measured program's stdout until it exits.
inline void announce_placement(int cpu, std::string_view role) {
  const std::string line = "placement pid=" + std::to_string(::getpid()) + " tid=" + std::to_string(current_tid()) +
                           " cpu=" + std::to_string(cpu) + " role=" + std::string{role};
  std::println("{}", line);
  std::fflush(stdout);
  if (const char* path = std::getenv("LOWLAT_PLACEMENT_FILE")) std::ofstream{path, std::ios::app} << line << '\n';
}

/// "2,4,6" -> {2, 4, 6}. Throws std::invalid_argument on anything else.
[[nodiscard]] inline std::vector<int> parse_cpu_list(std::string_view text) {
  std::vector<int> cpus;
  while (!text.empty()) {
    const auto comma = text.find(',');
    const std::string_view item = text.substr(0, comma);
    int cpu = -1;
    const auto [ptr, ec] = std::from_chars(item.data(), item.data() + item.size(), cpu);
    if (ec != std::errc{} || ptr != item.data() + item.size() || cpu < 0) {
      throw std::invalid_argument("bad CPU list: " + std::string{text});
    }
    cpus.push_back(cpu);
    text = comma == std::string_view::npos ? std::string_view{} : text.substr(comma + 1);
  }
  return cpus;
}

}  // namespace lowlat::eliminating
