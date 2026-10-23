// Wiring: the target links absl::flat_hash_map from the prefix and the map works.
#include <gtest/gtest.h>

#include <cstdint>

#include "lowlat/eliminating/wiring.hpp"

TEST(EliminatingWorkWiring, FlatHashMapRoundTrips) {
  absl::flat_hash_map<std::uint64_t, std::uint32_t> map;
  map[7] = 42;
  ASSERT_TRUE(map.contains(7));
  EXPECT_EQ(map.at(7), 42U);

  const auto filled = lowlat::eliminating::make_flat_map(100);
  EXPECT_EQ(filled.size(), 100U);
  EXPECT_EQ(filled.at(99), 99U);
}
