// Seeded barcodes for the working sets: distinct SSCC-18 keys, a shuffled lookup order, and the
// scans that fill a tracker.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <numeric>
#include <random>
#include <string>
#include <vector>

#include "lowlat/eliminating/records.hpp"
#include "lowlat/eliminating/sscc.hpp"

namespace lowlat::eliminating {

/// The same keys twice: the 18-digit text the wire carries (the node map's key) and the packed
/// integer (the open-addressing map's key).
struct Keys {
  std::vector<std::string> text;
  std::vector<std::uint64_t> packed;

  [[nodiscard]] std::size_t size() const noexcept { return packed.size(); }
};

inline constexpr std::uint64_t kSsccSpace = 1'000'000'000'000'000'000ULL;  // 10^18 values of 18 digits

/// Key number `i` of a seeded family: i * odd-multiplier mod 10^18. The multiplier is coprime to 10^18,
/// so distinct i give distinct keys, and the keys look random to a hash.
[[nodiscard]] inline std::uint64_t sscc_of(std::uint64_t seed, std::uint64_t i) noexcept {
  constexpr std::uint64_t kStride = 1'442'695'040'888'963'407ULL;  // odd, not a multiple of 5
  const unsigned __int128 product = static_cast<unsigned __int128>(i + seed * 0x9E3779B1ULL) * kStride;
  return static_cast<std::uint64_t>(product % kSsccSpace);
}

/// `n` distinct keys, in insertion order.
[[nodiscard]] inline Keys make_keys(std::size_t n, std::uint64_t seed) {
  Keys keys;
  keys.text.reserve(n);
  keys.packed.reserve(n);
  for (std::size_t i = 0; i < n; ++i) {
    keys.packed.push_back(sscc_of(seed, i));
    keys.text.push_back(format_sscc_string(keys.packed.back()));
  }
  return keys;
}

/// The first `n` keys of the family, visited in a seeded random order: lookups into a table that was
/// filled in insertion order, so the order of the lookups is not the order of the allocations.
[[nodiscard]] inline Keys make_lookup_keys(std::size_t n, std::uint64_t seed, std::uint64_t order_seed) {
  std::vector<std::uint32_t> order(n);
  std::iota(order.begin(), order.end(), 0U);
  std::mt19937_64 rng{order_seed};
  std::ranges::shuffle(order, rng);
  Keys keys;
  keys.text.reserve(n);
  keys.packed.reserve(n);
  for (const std::uint32_t i : order) {
    keys.packed.push_back(sscc_of(seed, i));
    keys.text.push_back(format_sscc_string(keys.packed.back()));
  }
  return keys;
}

/// Scan number `i` for `keys`: encoder tick i, so due ticks spread over the table.
[[nodiscard]] inline Scan scan_of(const Keys& keys, std::size_t i) noexcept {
  return Scan{.barcode = keys.text[i],
              .seq = i,
              .tick = i,
              .weight_g = static_cast<std::uint32_t>(500 + i % 20'000),
              .length_mm = static_cast<std::uint16_t>(150 + i % 1000),
              .width_mm = static_cast<std::uint16_t>(100 + i % 600),
              .height_mm = static_cast<std::uint16_t>(50 + i % 450),
              .confidence_permille = static_cast<std::uint16_t>(950 + i % 51)};
}

}  // namespace lowlat::eliminating
