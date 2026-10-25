#include "lowlat/measure/runtime.hpp"

#include <stdexcept>

namespace lowlat::measure {

nlohmann::json placement(std::span<const int> cpus, bool distinct_cores, bool smt_siblings) {
  return {{"cpus", cpus}, {"distinct_cores", distinct_cores}, {"smt_siblings", smt_siblings}};
}

nlohmann::json hw_counters(HwSource source, std::uint64_t ops, const std::map<std::string, double>& per_op) {
  if (ops == 0) throw std::invalid_argument("hw_counters: ops must be positive");
  return {{"source", source}, {"ops", ops}, {"per_op", per_op}};
}

namespace {
// An empty optional is written as null.
template <typename T>
nlohmann::json opt(const std::optional<T>& v) {
  return v ? nlohmann::json(*v) : nlohmann::json(nullptr);
}
}  // namespace

nlohmann::json environment(EnvKind kind, const std::optional<std::string>& guest_profile,
                           const std::optional<ContainerInfo>& container, const std::optional<CgroupInfo>& cgroup) {
  nlohmann::json env = {{"kind", kind}};
  if (guest_profile) env["guest_profile"] = *guest_profile;
  if (container) {
    env["container"] = {{"runtime", container->runtime},     {"image", container->image},
                        {"image_digest", container->image_digest}, {"network", container->network},
                        {"cpu_quota", opt(container->cpu_quota)},  {"cpuset", opt(container->cpuset)},
                        {"seccomp", container->seccomp}};
  }
  if (cgroup) {
    env["cgroup"] = {{"cpu_max", opt(cgroup->cpu_max)},
                     {"cpuset_effective", opt(cgroup->cpuset_effective)},
                     {"nr_throttled", opt(cgroup->nr_throttled)},
                     {"throttled_usec", opt(cgroup->throttled_usec)}};
  }
  return env;
}

nlohmann::json counters(const std::map<std::string, std::int64_t>& counts) { return counts; }

}  // namespace lowlat::measure
