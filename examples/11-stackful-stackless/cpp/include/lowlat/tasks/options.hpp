// The command-line options of the Ch11 executables: "--key value" pairs and bare "--flag" switches.
// Adapted from example 10's Options; parse errors come back as std::expected, not exceptions.
#pragma once

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <expected>
#include <format>
#include <initializer_list>
#include <map>
#include <string>
#include <string_view>

namespace lowlat::tasks {

class Options {
 public:
  /// Parses argv[first..argc). The names in `flags` take no value; every other option needs one.
  [[nodiscard]] static std::expected<Options, std::string> parse(int argc, char** argv, int first,
                                                                 std::initializer_list<std::string_view> flags = {}) {
    Options o;
    for (int i = first; i < argc; ++i) {
      std::string_view key{argv[i]};
      if (!key.starts_with("--")) return std::unexpected(std::format("unexpected argument '{}'", key));
      key.remove_prefix(2);
      if (std::ranges::find(flags, key) != flags.end()) {
        o.values_[std::string{key}] = "1";
      } else if (i + 1 < argc) {
        o.values_[std::string{key}] = argv[++i];
      } else {
        return std::unexpected(std::format("--{} needs a value", key));
      }
    }
    return o;
  }

  [[nodiscard]] bool flag(const std::string& key) const { return values_.contains(key); }

  [[nodiscard]] std::string text(const std::string& key, std::string fallback) const {
    const auto it = values_.find(key);
    return it == values_.end() ? fallback : it->second;
  }

  /// The option as an unsigned integer; "12abc", "-1" and "" are errors.
  [[nodiscard]] std::expected<std::uint64_t, std::string> number(const std::string& key, std::uint64_t fallback) const {
    const auto it = values_.find(key);
    if (it == values_.end()) return fallback;
    std::uint64_t v = 0;
    const std::string& s = it->second;
    const auto [end, ec] = std::from_chars(s.data(), s.data() + s.size(), v);
    if (s.empty() || ec != std::errc{} || end != s.data() + s.size()) {
      return std::unexpected(std::format("--{} needs a non-negative integer, got '{}'", key, s));
    }
    return v;
  }

 private:
  std::map<std::string, std::string> values_;
};

}  // namespace lowlat::tasks
