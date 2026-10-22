// Helpers shared by the line's hand-written command-line parsers (the
// simulator's config.cpp and the consumers' options).
#pragma once

#include <charconv>
#include <format>
#include <stdexcept>
#include <string>
#include <string_view>

namespace lowlat::line::cli {

[[noreturn]] inline void fail(std::string_view message) { throw std::invalid_argument(std::string{message}); }

/// Parses all of `text` as a T; anything left over is an error.
template <typename T>
T number(std::string_view option, std::string_view text) {
  T value{};
  const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), value);
  if (ec != std::errc{} || end != text.data() + text.size()) {
    fail(std::format("{}: '{}' is not a valid number", option, text));
  }
  return value;
}

}  // namespace lowlat::line::cli
