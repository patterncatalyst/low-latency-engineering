// The command-line options of the Ch10 executables: "--key value" pairs and bare "--flag" switches.
#pragma once

#include <algorithm>
#include <cstdint>
#include <format>
#include <initializer_list>
#include <map>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "lowlat/line/cli.hpp"

namespace lowlat::lockfree {

class Options {
 public:
  /// Parses argv[first..argc). The names in `flags` take no value; every other option needs one.
  Options(int argc, char** argv, int first, std::initializer_list<std::string_view> flags = {}) {
    for (int i = first; i < argc; ++i) {
      std::string_view key{argv[i]};
      if (!key.starts_with("--")) throw std::invalid_argument(std::format("unexpected argument '{}'", key));
      key.remove_prefix(2);
      if (std::ranges::find(flags, key) != flags.end()) {
        values_[std::string{key}] = "1";
      } else if (i + 1 < argc) {
        values_[std::string{key}] = argv[++i];
      } else {
        throw std::invalid_argument(std::format("--{} needs a value", key));
      }
    }
  }

  [[nodiscard]] bool flag(const std::string& key) const { return values_.contains(key); }

  [[nodiscard]] std::string text(const std::string& key, std::string fallback) const {
    const auto it = values_.find(key);
    return it == values_.end() ? fallback : it->second;
  }

  /// The option as an unsigned integer; "12abc", "-1" and "" throw std::invalid_argument.
  [[nodiscard]] std::uint64_t number(const std::string& key, std::uint64_t fallback) const {
    const auto it = values_.find(key);
    return it == values_.end() ? fallback : line::cli::number<std::uint64_t>("--" + key, it->second);
  }

 private:
  std::map<std::string, std::string> values_;
};

}  // namespace lowlat::lockfree
