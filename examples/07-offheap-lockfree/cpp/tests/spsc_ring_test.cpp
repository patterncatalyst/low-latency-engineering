// SpscRing: single-thread behaviour, then two threads in both waiting styles.
#include <gtest/gtest.h>

#include <cstdint>
#include <thread>

#include "lowlat/offheap/spsc_ring.hpp"

namespace {

using lowlat::offheap::SpscRing;

TEST(SpscRing, IndicesLiveOnSeparateCacheLines) {
  EXPECT_TRUE((SpscRing<std::uint64_t, 8>::indices_on_separate_lines()));
}

TEST(SpscRing, PopsInPushOrderAndReportsEmpty) {
  SpscRing<std::uint64_t, 8> ring;
  EXPECT_FALSE(ring.try_pop());
  for (std::uint64_t i = 0; i < 5; ++i) EXPECT_TRUE(ring.try_push(i));
  for (std::uint64_t i = 0; i < 5; ++i) EXPECT_EQ(ring.try_pop(), i);
  EXPECT_FALSE(ring.try_pop());
}

TEST(SpscRing, RefusesWhenFullAndReusesFreedSlots) {
  SpscRing<std::uint64_t, 4> ring;
  for (std::uint64_t i = 0; i < 4; ++i) EXPECT_TRUE(ring.try_push(i));
  EXPECT_FALSE(ring.try_push(99));
  EXPECT_EQ(ring.try_pop(), 0u);
  EXPECT_TRUE(ring.try_push(4));  // the freed slot, after the index has wrapped the mask once
  for (std::uint64_t i = 1; i <= 4; ++i) EXPECT_EQ(ring.try_pop(), i);
}

// 200,000 records through a 64-slot ring: every one arrives once, in order.
template <bool Park>
void transfers_in_order() {
  constexpr std::uint64_t kCount = 200'000;
  SpscRing<std::uint64_t, 64> ring;
  std::thread producer{[&] {
    for (std::uint64_t i = 0; i < kCount; ++i) {
      while (!ring.try_push(i)) std::this_thread::yield();
      if constexpr (Park) ring.notify_consumer();
    }
  }};
  std::uint64_t expected = 0;
  while (expected < kCount) {
    if (const auto v = ring.try_pop()) {
      ASSERT_EQ(*v, expected);
      ++expected;
    } else if constexpr (Park) {
      ring.wait_for_data();
    }
  }
  producer.join();
  EXPECT_FALSE(ring.try_pop());
}

TEST(SpscRing, TwoThreadsSpinning) { transfers_in_order<false>(); }
TEST(SpscRing, TwoThreadsParking) { transfers_in_order<true>(); }

}  // namespace
