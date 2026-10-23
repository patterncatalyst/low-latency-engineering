// Simulator configuration and its command-line parser.
//
// No third-party argument parser: nine options, all `--name value`, and
// std::from_chars does the number parsing. A library would be more code than
// the table below.
#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace lowlat::line {

/// What a datagram carries: the protobuf ParcelEvent (default) or the flat
/// little-endian record of contracts/flat/parcel-v1.
enum class Wire : std::uint8_t { protobuf, flat };

struct Config {
  std::uint32_t rate_hz = 1000;
  double duration_s = 10.0;
  double belt_speed_mps = 2.5;
  double scan_to_divert_m = 1.2;
  std::uint32_t encoder_ppm = 1000;  ///< Encoder pulses per metre of belt.
  std::uint64_t seed = 42;
  std::string dest = "127.0.0.1:47000";  ///< host:port (IPv4).
  std::optional<std::filesystem::path> report;
  Wire wire = Wire::protobuf;
  bool quiet = false;
};

/// Parses `args` (argv without the program name). Throws std::invalid_argument
/// with a message for the user on any unknown option, missing value or value
/// out of range. `--help` is handled by the caller (see usage()).
[[nodiscard]] Config parse_args(std::span<const std::string_view> args);

/// Help text: the option table.
[[nodiscard]] std::string_view usage() noexcept;

/// Number of parcels the run emits: round(duration x rate).
[[nodiscard]] std::uint64_t parcel_count(const Config& c) noexcept;

}  // namespace lowlat::line
