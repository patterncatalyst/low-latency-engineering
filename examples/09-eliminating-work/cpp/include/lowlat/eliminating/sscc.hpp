// SSCC-18 barcode <-> 64-bit key. The wire carries the barcode as 18 ASCII digits; the open-addressing
// map keys on the packed integer, so the packing happens once, at the edge, with std::from_chars.
#pragma once

#include <array>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>

namespace lowlat::eliminating {

inline constexpr std::size_t kSsccDigits = 18;

/// The 18 digits as an integer (below 10^18, so it fits 63 bits), or nullopt unless the text is
/// exactly 18 ASCII digits. A leading zero is a digit: "000000000000000042" packs to 42.
[[nodiscard]] inline std::optional<std::uint64_t> pack_sscc(std::string_view digits) noexcept {
  if (digits.size() != kSsccDigits) return std::nullopt;
  std::uint64_t value = 0;
  const char* const end = digits.data() + digits.size();
  const auto [ptr, ec] = std::from_chars(digits.data(), end, value);
  if (ec != std::errc{} || ptr != end) return std::nullopt;
  return value;
}

/// The inverse: `value` as 18 zero-padded digits (std::to_chars cannot pad, so the digits are peeled
/// off from the right). `value` must be below 10^18.
[[nodiscard]] inline std::array<char, kSsccDigits> format_sscc(std::uint64_t value) noexcept {
  std::array<char, kSsccDigits> out{};
  for (auto it = out.rbegin(); it != out.rend(); ++it, value /= 10) *it = static_cast<char>('0' + value % 10);
  return out;
}

[[nodiscard]] inline std::string format_sscc_string(std::uint64_t value) {
  const auto digits = format_sscc(value);
  return {digits.data(), digits.size()};
}

}  // namespace lowlat::eliminating
