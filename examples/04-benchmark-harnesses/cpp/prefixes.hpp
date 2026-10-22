// The fixed set of 17-digit SSCC prefixes every language benchmarks:
// prefix i = extension (i % 10), company prefix 0614141, serial (i * 7919 + 13) % 10^9
// zero-padded to nine digits. Java and Python build the identical set.
#pragma once

#include <cstddef>
#include <format>
#include <string>
#include <vector>

namespace lowlat::bench {

[[nodiscard]] inline std::vector<std::string> make_prefixes(std::size_t n) {
  std::vector<std::string> out;
  out.reserve(n);
  for (std::size_t i = 0; i < n; ++i) {
    out.push_back(std::format("{}0614141{:09}", i % 10, (i * 7919 + 13) % 1'000'000'000));
  }
  return out;
}

}  // namespace lowlat::bench
