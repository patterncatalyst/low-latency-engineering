// Reading a whole binary file as bytes: the golden files and the flat-dump tool use this one helper.
#pragma once

#include <algorithm>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

namespace lowlat::line {

/// The file's contents. Throws std::runtime_error when it cannot be opened.
[[nodiscard]] inline std::vector<std::byte> read_binary_file(const std::filesystem::path& path) {
  std::ifstream in{path, std::ios::binary};
  if (!in) throw std::runtime_error("cannot open " + path.string());
  const std::vector<char> raw{std::istreambuf_iterator<char>{in}, std::istreambuf_iterator<char>{}};
  std::vector<std::byte> out(raw.size());
  std::ranges::copy(std::as_bytes(std::span{raw}), out.begin());
  return out;
}

}  // namespace lowlat::line
