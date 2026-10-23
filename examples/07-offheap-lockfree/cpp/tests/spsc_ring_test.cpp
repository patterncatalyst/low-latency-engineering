// SpscRing: single-thread behaviour, then two threads in both waiting styles.
#include <gtest/gtest.h>

#include <cstdint>
#include <new>
#include <stop_token>
#include <thread>

#include "lowlat/offheap/spsc_ring.hpp"

namespace {

using lowlat::offheap::SpscRing;

TEST(SpscRing, IndicesLiveInSeparateFalseSharingRanges) {
  EXPECT_TRUE((SpscRing<std::uint64_t, 8>::indices_on_separate_lines()));
  EXPECT_EQ(lowlat::offheap::kFalseSharingRange, 2 * std::hardware_destructive_interference_size);
  EXPECT_GE((alignof(SpscRing<std::uint64_t, 8>)), lowlat::offheap::kFalseSharingRange);
}

TEST(SpscRing, ReusesSlotsAcrossManyMaskWraps) {
  // A 4-slot ring wraps the mask every 4 pushes; 100,000 pairs exercise the index arithmetic.
  SpscRing<std::uint64_t, 4> ring;
  for (std::uint64_t i = 0; i < 100'000; ++i) {
    ASSERT_TRUE(ring.try_push(i));
    ASSERT_EQ(ring.try_pop(), i);
  }
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

// 200,000 records through a 64-slot ring: every one arrives once, in order. A failed check ends the
// consumer loop and asks the producer to stop (it could otherwise spin on a full ring for ever).
template <bool Park>
void transfers_in_order() {
  constexpr std::uint64_t kCount = 200'000;
  SpscRing<std::uint64_t, 64> ring;
  std::uint64_t expected = 0;
  {
    std::jthread producer{[&](std::stop_token stop) {
      for (std::uint64_t i = 0; i < kCount; ++i) {
        while (!ring.try_push(i)) {
          if (stop.stop_requested()) return;
          std::this_thread::yield();
        }
        if constexpr (Park) ring.notify_consumer();
      }
    }};
    while (expected < kCount) {
      if (const auto v = ring.try_pop()) {
        EXPECT_EQ(*v, expected);
        if (*v != expected) break;
        ++expected;
      } else if constexpr (Park) {
        ring.wait_for_data();
      }
    }
    producer.request_stop();
  }  // the jthread joins here
  EXPECT_EQ(expected, kCount);
  EXPECT_FALSE(ring.try_pop());
}

TEST(SpscRing, TwoThreadsSpinning) { transfers_in_order<false>(); }
TEST(SpscRing, TwoThreadsParking) { transfers_in_order<true>(); }

}  // namespace
