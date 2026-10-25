// place-probe: what this process sees of its CPUs, and whether io_uring_setup works here.
//
//   place-probe [--out FILE]      one JSON object (lowlat-place-probe/1), on stdout or in FILE
//
// The same binary runs on the host, in the guest and in a container, so each environment's answer is
// the answer of identical code. It reports std::thread::hardware_concurrency(), the CPU count the
// kernel says is online, the size of the affinity mask, the cgroup's cpu.max, cpuset.cpus.effective
// and cpu.stat, and two pool sizes: the one a "one worker per hardware thread" rule picks, and the
// one a cgroup-aware rule would. A file that cannot be read is a null with the reason in "errors".
//
// Provenance: adapted from cgroup_probe in the companion project cpp-concurrency-and-parallelism (Ch32).
#include <gnu/libc-version.h>
#include <sched.h>

#include <algorithm>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <print>
#include <string>
#include <thread>

#include <nlohmann/json.hpp>

#include "cgroup_probe.hpp"
#include "lowlat/lockfree/options.hpp"

namespace {

namespace place = lowlat::place;
using nlohmann::json;

std::size_t affinity_count() {
  cpu_set_t set;
  CPU_ZERO(&set);
  if (sched_getaffinity(0, sizeof set, &set) != 0) return 0;
  return static_cast<std::size_t>(CPU_COUNT(&set));
}

json probe() {
  json out;
  json errors = json::array();
  const auto note = [&errors](const std::string& what, const std::string& why) { errors.push_back(what + ": " + why); };

  const std::size_t hardware = std::thread::hardware_concurrency();
  const std::size_t affinity = affinity_count();
  json cpus;
  cpus["hardware_concurrency"] = hardware;
  cpus["affinity_count"] = affinity;
  cpus["online"] = nullptr;
  cpus["online_count"] = nullptr;
  if (auto online = place::read_online_cpus()) {
    cpus["online"] = *online;
    if (auto n = place::count_cpus(*online)) cpus["online_count"] = *n;
    else note("online count", n.error());
  } else {
    note("online", online.error());
  }

  json cgroup;
  cgroup["cpu_max"] = nullptr;
  cgroup["quota_cpus"] = nullptr;
  cgroup["cpuset_effective"] = nullptr;
  cgroup["cpuset_count"] = nullptr;
  cgroup["cpu_stat"] = nullptr;
  std::optional<long> quota;
  if (auto max = place::read_cpu_max()) {
    cgroup["cpu_max"] = max->quota_us ? std::to_string(*max->quota_us) + " " + std::to_string(max->period_us) : "max " + std::to_string(max->period_us);
    quota = place::quota_cpus(*max);
    if (quota) cgroup["quota_cpus"] = *quota;
  } else {
    note("cpu.max", max.error());
  }
  std::optional<std::size_t> cpuset;
  if (auto eff = place::read_cpuset_effective()) {
    cgroup["cpuset_effective"] = *eff;
    if (auto n = place::count_cpus(*eff)) {
      cpuset = *n;
      cgroup["cpuset_count"] = *n;
    } else {
      note("cpuset count", n.error());
    }
  } else {
    note("cpuset.cpus.effective", eff.error());
  }
  if (auto stat = place::read_cpu_stat()) {
    json values = json::object();
    for (const auto& [key, value] : stat->values) values[key] = value;
    cgroup["cpu_stat"] = std::move(values);
  } else {
    note("cpu.stat", stat.error());
  }

  // The size a "one worker per hardware thread" rule picks, and the size a rule that honours the
  // cgroup would pick (the smaller of the hardware count, the quota rounded up and the cpuset).
  std::size_t aware = hardware;
  if (quota && *quota > 0) aware = std::min(aware, static_cast<std::size_t>(*quota));
  if (cpuset && *cpuset > 0) aware = std::min(aware, *cpuset);
  json pool;
  pool["by_hardware_concurrency"] = hardware;
  pool["cgroup_aware"] = aware;

  const std::error_code setup = place::io_uring_setup_error();
  json uring;
  uring["setup_errno"] = setup.value();
  uring["setup_result"] = place::errno_name(setup.value());

  out["schema"] = "lowlat-place-probe/1";
  out["example"] = "13-where-code-runs";
  out["language"] = "cpp";
  out["cpus"] = std::move(cpus);
  out["cgroup"] = std::move(cgroup);
  out["pool_size"] = std::move(pool);
  out["libc"] = {{"glibc", gnu_get_libc_version()}};  // the one dynamic dependency left: it differs between the host, the guest and the image
  out["io_uring"] = std::move(uring);
  out["errors"] = std::move(errors);
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const lowlat::lockfree::Options options{argc, argv, 1};
    const std::string text = probe().dump(2) + "\n";
    if (const std::string path = options.text("out", ""); !path.empty()) {
      std::ofstream file{path};
      if (!(file << text)) {
        std::println(stderr, "place-probe: cannot write {}", path);
        return EXIT_FAILURE;
      }
    } else {
      std::print("{}", text);
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "place-probe: {}", e.what());
    return EXIT_FAILURE;
  }
}
