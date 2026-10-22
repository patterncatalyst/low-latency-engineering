// The model functions are the arithmetic the verify.sh criteria rest on.
#include <gtest/gtest.h>

#include "lowlat/ch02/model.hpp"

namespace ch02 = lowlat::ch02;

TEST(Amdahl, OneWorkerIsOne) { EXPECT_DOUBLE_EQ(ch02::amdahl_speedup(0.1, 1), 1.0); }

TEST(Amdahl, TenPercentSerial) {
  EXPECT_NEAR(ch02::amdahl_speedup(0.1, 2), 1.0 / 0.55, 1e-12);
  EXPECT_NEAR(ch02::amdahl_speedup(0.1, 4), 1.0 / 0.325, 1e-12);
  EXPECT_LT(ch02::amdahl_speedup(0.1, 1'000'000), 10.0);  // bounded by 1 / s
}

TEST(Amdahl, FullyParallelIsLinear) { EXPECT_DOUBLE_EQ(ch02::amdahl_speedup(0.0, 8), 8.0); }

TEST(Arrivals, ScheduleCount) {
  constexpr std::int64_t t0 = 5'000'000'000;
  EXPECT_EQ(ch02::arrivals_by(t0 - 1, t0, 1000), 0);
  EXPECT_EQ(ch02::arrivals_by(t0, t0, 1000), 1);                 // parcel 0 is due at t0
  EXPECT_EQ(ch02::arrivals_by(t0 + 999'999, t0, 1000), 1);
  EXPECT_EQ(ch02::arrivals_by(t0 + 1'000'000, t0, 1000), 2);     // parcel 1 is due 1 ms later
  EXPECT_EQ(ch02::arrivals_by(t0 + 10'000'000'000, t0, 1000), 10'001);
}

TEST(Littles, WarehouseFraming) {
  // 480 ms scan-to-divert at 1 kHz: 480 parcels between scanner and diverter.
  EXPECT_DOUBLE_EQ(ch02::littles_L(1000.0, 0.480), 480.0);
}
