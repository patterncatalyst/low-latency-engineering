// Wiring: the header-only target compiles and links.
#include <gtest/gtest.h>

#include "lowlat/lockfree/wiring.hpp"

TEST(LockfreeWiring, ClaimsAreSequential) {
  lowlat::lockfree::FetchAddClaim log;
  EXPECT_EQ(log.claim(), 0U);
  EXPECT_EQ(log.claim(), 1U);
}
