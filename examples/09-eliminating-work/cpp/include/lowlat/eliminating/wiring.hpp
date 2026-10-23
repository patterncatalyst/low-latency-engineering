// Build wiring for Ch9 (S4); replaced by the real variants in S5.
#pragma once

#include <cstdint>

#include "absl/container/flat_hash_map.h"

namespace lowlat::eliminating {

// The open-addressing table Ch9 compares against std::unordered_map.
using FlatMap = absl::flat_hash_map<std::uint64_t, std::uint32_t>;

// Inserts `n` keys (0..n-1, value = key) and returns the table.
FlatMap make_flat_map(std::uint64_t n);

}  // namespace lowlat::eliminating
