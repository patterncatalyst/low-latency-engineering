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

nlohmann::json counters(const std::map<std::string, std::int64_t>& counts) { return counts; }

}  // namespace lowlat::measure
