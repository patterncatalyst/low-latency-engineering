// SSCC-18 (GS1 Serial Shipping Container Code) helpers.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace lowlat::line {

/// GS1 mod-10 check digit for the first 17 digits of an SSCC-18.
/// Digits are weighted 3,1,3,1,... starting from the rightmost of the 17; the
/// check digit brings the weighted sum up to a multiple of ten.
/// Throws std::invalid_argument unless `digits17` is exactly 17 ASCII digits.
[[nodiscard]] int sscc_check_digit(std::string_view digits17);

/// True when `sscc` is 18 ASCII digits whose last digit is the correct check digit.
[[nodiscard]] bool is_valid_sscc(std::string_view sscc) noexcept;

/// Builds a valid SSCC-18: extension digit, 7-digit company prefix, 9-digit
/// serial reference (zero padded), then the check digit.
/// `extension` is 0..9; `serial` is taken modulo 10^9.
[[nodiscard]] std::string make_sscc(int extension, std::string_view company_prefix7, std::uint64_t serial);

}  // namespace lowlat::line
