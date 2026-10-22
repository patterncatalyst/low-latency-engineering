// SSCC-18 (GS1 Serial Shipping Container Code) helpers.
#pragma once

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>

namespace lowlat::line {

/// True when every character of `s` is an ASCII digit (an empty view is true).
[[nodiscard]] constexpr bool is_ascii_digits(std::string_view s) noexcept {
  return std::ranges::all_of(s, [](char c) { return c >= '0' && c <= '9'; });
}

/// GS1 mod-10 check digit for the first 17 digits of an SSCC-18.
/// Digits are weighted 3,1,3,1,... starting from the rightmost of the 17; the
/// check digit brings the weighted sum up to a multiple of ten.
/// Throws std::invalid_argument unless `digits17` is exactly 17 ASCII digits.
[[nodiscard]] int sscc_check_digit(std::string_view digits17);

/// True when `sscc` is 18 ASCII digits whose last digit is the correct check digit.
[[nodiscard]] bool is_valid_sscc(std::string_view sscc) noexcept;

/// The 9-digit serial reference (digits 9..17) of an SSCC-18 as a number. The
/// check digit is not verified: this is the lane-routing key, not validation.
/// Throws std::invalid_argument unless `sscc` is 18 ASCII digits.
/// Inline: it is the per-parcel routing step the consumers measure.
[[nodiscard]] inline std::uint64_t sscc_serial(std::string_view sscc) {
  constexpr std::size_t kSerialAt = 8, kSerialLen = 9;  // extension + 7-digit prefix come first
  if (sscc.size() != 18 || !is_ascii_digits(sscc)) throw std::invalid_argument("SSCC must be 18 ASCII digits");
  std::uint64_t serial = 0;
  std::from_chars(sscc.data() + kSerialAt, sscc.data() + kSerialAt + kSerialLen, serial);  // digits validated above
  return serial;
}

/// Builds a valid SSCC-18: extension digit, 7-digit company prefix, 9-digit
/// serial reference (zero padded), then the check digit.
/// `extension` is 0..9; `serial` is taken modulo 10^9.
[[nodiscard]] std::string make_sscc(int extension, std::string_view company_prefix7, std::uint64_t serial);

}  // namespace lowlat::line
