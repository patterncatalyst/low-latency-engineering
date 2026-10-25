#include "placement.hpp"

#include <sched.h>
#include <sys/resource.h>

#include <cerrno>
#include <format>
#include <system_error>

#include "lowlat/cyclic/probe.hpp"

namespace lowlat::placement {
namespace {

std::string errno_text(const char* call, int err) {
  return std::format("{}: {}", call, std::system_category().message(err));
}

// The compiler must not remove the spin; a volatile sink is the standard way to keep a busy loop.
volatile std::uint64_t spin_sink = 0;

}  // namespace

std::string format_cpu_list(const std::vector<int>& cpus) {
  std::string out;
  for (std::size_t i = 0; i < cpus.size();) {
    std::size_t j = i;
    while (j + 1 < cpus.size() && cpus[j + 1] == cpus[j] + 1) ++j;
    if (!out.empty()) out += ',';
    out += j == i ? std::format("{}", cpus[i]) : std::format("{}-{}", cpus[i], cpus[j]);
    i = j + 1;
  }
  return out;
}

std::expected<std::vector<int>, std::string> affinity_cpus() {
  cpu_set_t set;
  CPU_ZERO(&set);
  if (sched_getaffinity(0, sizeof set, &set) != 0) return std::unexpected{errno_text("sched_getaffinity", errno)};
  std::vector<int> cpus;
  for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu) {
    if (CPU_ISSET(cpu, &set)) cpus.push_back(cpu);
  }
  return cpus;
}

std::expected<int, std::string> current_cpu() {
  const int cpu = sched_getcpu();
  if (cpu < 0) return std::unexpected{errno_text("sched_getcpu", errno)};
  return cpu;
}

std::expected<Switches, std::string> thread_switches() {
  rusage usage{};
  if (getrusage(RUSAGE_THREAD, &usage) != 0) return std::unexpected{errno_text("getrusage", errno)};
  return Switches{usage.ru_nvcsw, usage.ru_nivcsw};
}

std::expected<nlohmann::json, std::string> probe(int cpu, std::chrono::milliseconds busy) {
  if (cpu >= 0) {
    if (auto ok = cyclic::pin_to_cpu(cpu); !ok) return std::unexpected{ok.error()};
  }
  const auto allowed = affinity_cpus();
  if (!allowed) return std::unexpected{allowed.error()};
  const auto first = current_cpu();
  if (!first) return std::unexpected{first.error()};
  const auto before = thread_switches();
  if (!before) return std::unexpected{before.error()};

  for (const auto end = std::chrono::steady_clock::now() + busy; std::chrono::steady_clock::now() < end;) {
    spin_sink = spin_sink + 1;
  }

  const auto last = current_cpu();
  if (!last) return std::unexpected{last.error()};
  const auto after = thread_switches();
  if (!after) return std::unexpected{after.error()};

  nlohmann::json out;
  out["schema"] = "lowlat-placement-probe/1";
  out["example"] = "15-cpu-partitioning";
  out["language"] = "cpp";
  out["affinity"] = format_cpu_list(*allowed);
  out["cpu_at_start"] = *first;
  out["cpu_at_end"] = *last;
  out["context_switches"] = {{"voluntary", after->voluntary - before->voluntary},
                             {"involuntary", after->involuntary - before->involuntary}};
  out["busy_ms"] = busy.count();
  return out;
}

}  // namespace lowlat::placement
