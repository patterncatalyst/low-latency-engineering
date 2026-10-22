// SSCC-18 GS1 mod-10 check digit, header-only so the optimizer can see through it.
//
// Same algorithm as lowlat::line::sscc_check_digit (common/line-simulator), minus
// the validation: weights 3,1,3,1,... from the rightmost of the 17 digits, check
// digit = (10 - sum % 10) % 10. The benchmark needs the body inlinable (the
// line-simulator copy lives in another translation unit), and check_digit_test.cpp
// asserts the two agree. Callers pass exactly 17 ASCII digits.
#pragma once

#include <cstddef>
#include <string_view>

namespace lowlat::bench {

inline constexpr std::size_t kBodyDigits = 17;

[[nodiscard]] constexpr int check_digit(std::string_view digits17) noexcept {
  int sum = 0;
  int weight = 3;  // the digit next to the check digit weighs 3
  for (std::size_t i = kBodyDigits; i-- > 0;) {
    sum += (digits17[i] - '0') * weight;
    weight = 4 - weight;  // 3 <-> 1
  }
  return (10 - sum % 10) % 10;
}

}  // namespace lowlat::bench
