#include "lowlat/line/sscc.hpp"

#include <format>
#include <stdexcept>

namespace lowlat::line {

int sscc_check_digit(std::string_view digits17) {
  if (digits17.size() != 17 || !is_ascii_digits(digits17)) {
    throw std::invalid_argument(std::format("SSCC body must be 17 digits, got '{}'", digits17));
  }
  int sum = 0;
  int weight = 3;  // the digit next to the check digit weighs 3
  for (auto it = digits17.rbegin(); it != digits17.rend(); ++it) {
    sum += (*it - '0') * weight;
    weight = 4 - weight;  // 3 <-> 1
  }
  return (10 - sum % 10) % 10;
}

bool is_valid_sscc(std::string_view sscc) noexcept {
  if (sscc.size() != 18 || !is_ascii_digits(sscc)) return false;
  return sscc_check_digit(sscc.substr(0, 17)) == sscc.back() - '0';
}

std::string make_sscc(int extension, std::string_view company_prefix7, std::uint64_t serial) {
  if (extension < 0 || extension > 9 || company_prefix7.size() != 7 || !is_ascii_digits(company_prefix7)) {
    throw std::invalid_argument("make_sscc: extension 0..9 and a 7-digit company prefix required");
  }
  std::string body = std::format("{}{}{:09}", extension, company_prefix7, serial % 1'000'000'000ULL);
  body += static_cast<char>('0' + sscc_check_digit(body));
  return body;
}

}  // namespace lowlat::line
