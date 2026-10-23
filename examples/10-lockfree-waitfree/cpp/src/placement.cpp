#include "lowlat/lockfree/placement.hpp"

#include <pthread.h>
#include <sched.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <charconv>
#include <cstdio>
#include <format>
#include <fstream>
#include <map>
#include <mutex>
#include <print>
#include <ranges>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <utility>

#include "lowlat/measure/runtime.hpp"

namespace lowlat::lockfree {

std::vector<int> parse_cpu_list(std::string_view csv) {
  std::vector<int> cpus;
  for (const auto part : std::views::split(csv, ',')) {
    const std::string_view text{part.begin(), part.end()};
    int cpu = -1;
    const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), cpu);
    if (ec != std::errc{} || end != text.data() + text.size() || cpu < 0) {
      throw std::invalid_argument(std::format("--cpus: '{}' is not a CPU number", text));
    }
    cpus.push_back(cpu);
  }
  if (cpus.empty()) throw std::invalid_argument("--cpus: empty list");
  return cpus;
}

void pin_current_thread(int cpu) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  if (const int rc = pthread_setaffinity_np(pthread_self(), sizeof set, &set); rc != 0) {
    throw std::system_error(rc, std::generic_category(), std::format("pthread_setaffinity_np(cpu {})", cpu));
  }
  // The thread migrates as soon as it is rescheduled; yield once so that sched_getcpu() answers for
  // the new CPU.
  sched_yield();
  if (const int on = sched_getcpu(); on != cpu) {
    throw std::runtime_error(std::format("pinned to CPU {} but running on CPU {}", cpu, on));
  }
}

std::int64_t current_tid() noexcept { return ::gettid(); }

CtxSwitches thread_ctx_switches() {
  std::ifstream status{"/proc/thread-self/status"};
  if (!status) throw std::runtime_error("cannot read /proc/thread-self/status");
  CtxSwitches out;
  for (std::string line; std::getline(status, line);) {
    if (line.starts_with("voluntary_ctxt_switches:")) out.voluntary = std::stoll(line.substr(24));
    if (line.starts_with("nonvoluntary_ctxt_switches:")) out.involuntary = std::stoll(line.substr(27));
  }
  return out;
}

namespace {

std::pair<int, int> core_of(int cpu) {
  const auto read = [&](const char* file, int fallback) {
    std::ifstream in{std::format("/sys/devices/system/cpu/cpu{}/topology/{}", cpu, file)};
    int v = fallback;
    in >> v;
    return v;
  };
  return {read("physical_package_id", 0), read("core_id", cpu)};
}

}  // namespace

nlohmann::json placement_of(std::span<const int> cpus) {
  std::map<std::pair<int, int>, int> per_core;
  for (const int cpu : cpus) ++per_core[core_of(cpu)];
  const bool siblings = std::ranges::any_of(per_core, [](const auto& kv) { return kv.second > 1; });
  return measure::placement(cpus, !siblings, siblings);
}

void Gate::worker_ready(int cpu, std::string role) {
  if (cpu >= 0) pin_current_thread(cpu);
  {
    const std::scoped_lock lock{mutex_};
    entries_.push_back({current_tid(), cpu, std::move(role)});
  }
  ready_.arrive_and_wait();
  go_.arrive_and_wait();
}

void Gate::release() {
  ready_.arrive_and_wait();
  {
    const std::scoped_lock lock{mutex_};
    for (const Entry& e : entries_) {
      std::println("pinned pid={} tid={} cpu={} role={}", ::getpid(), e.tid, e.cpu, e.role);
    }
  }
  std::println("placement-ready");
  std::fflush(stdout);
  std::this_thread::sleep_for(hold_);
  std::println("released");
  std::fflush(stdout);
  go_.arrive_and_wait();
}

std::vector<int> Gate::cpus() const {
  const std::scoped_lock lock{mutex_};
  std::vector<int> out;
  for (const Entry& e : entries_) {
    if (e.cpu >= 0) out.push_back(e.cpu);
  }
  return out;
}

}  // namespace lowlat::lockfree
