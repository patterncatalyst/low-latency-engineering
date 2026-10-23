#include "lowlat/eliminating/wiring.hpp"

namespace lowlat::eliminating {

FlatMap make_flat_map(std::uint64_t n) {
  FlatMap map;
  map.reserve(n);
  for (std::uint64_t i = 0; i < n; ++i) {
    map.emplace(i, static_cast<std::uint32_t>(i));
  }
  return map;
}

}  // namespace lowlat::eliminating
