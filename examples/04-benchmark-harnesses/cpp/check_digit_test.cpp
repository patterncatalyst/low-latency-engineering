// Parity: the benchmark's inline check digit equals the line-simulator reference on
// GS1 known-good SSCCs and on the whole benchmark prefix set.
#include <gtest/gtest.h>

#include <string>

#include "check_digit.hpp"
#include "lowlat/line/sscc.hpp"
#include "prefixes.hpp"

namespace {

struct Known {
  const char* body;
  int digit;
};

TEST(CheckDigit, KnownGoodSscc) {
  // GS1 General Specifications example 10614141123456789 -> 7; the others are the
  // same weighted sums worked by hand and confirmed against the reference.
  constexpr Known kKnown[] = {
      {"10614141123456789", 7},
      {"00614141000000007", 4},
      {"00000000000000000", 0},
  };
  for (const auto& k : kKnown) {
    EXPECT_EQ(lowlat::bench::check_digit(k.body), k.digit) << k.body;
    EXPECT_EQ(lowlat::line::sscc_check_digit(k.body), k.digit) << k.body;
  }
}

TEST(CheckDigit, MatchesReferenceOnBenchmarkPrefixes) {
  for (const std::string& prefix : lowlat::bench::make_prefixes(1024)) {
    ASSERT_EQ(lowlat::bench::check_digit(prefix), lowlat::line::sscc_check_digit(prefix)) << prefix;
    ASSERT_TRUE(lowlat::line::is_valid_sscc(prefix + std::to_string(lowlat::bench::check_digit(prefix))));
  }
}

}  // namespace
