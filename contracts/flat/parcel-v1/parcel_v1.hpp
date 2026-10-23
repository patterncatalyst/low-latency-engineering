// Flat wire format "parcel-v1": one ParcelEvent as a fixed 80-byte little-endian
// record. Source of truth for the layout; README.md explains it and the golden
// files pin it. The Java (FFM) and Python (struct) readers follow this file.
//
// The record is the in-memory object: no parse step, no allocation. A reader
// checks the first four bytes (schema_id, version) and then reads fields at
// fixed offsets. The protobuf contract (contracts/proto) stays the default wire;
// this is the layout the zero-copy chapter measures against it.
#pragma once

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <expected>
#include <span>
#include <string_view>
#include <type_traits>

namespace lowlat::flat::parcel_v1 {

// The wire is little-endian. A big-endian host would need byte swaps in encode
// and decode; none is supported, so the build says so instead of misreading.
static_assert(std::endian::native == std::endian::little, "parcel-v1 is little-endian; this host is not");

inline constexpr std::uint16_t kSchemaId = 1;  ///< lowlat.line.v1.ParcelEvent
inline constexpr std::uint16_t kVersion = 1;   ///< Layout revision of this schema.
inline constexpr std::size_t kSize = 80;       ///< Bytes on the wire, always.
inline constexpr std::size_t kBarcodeLen = 18;

/// The record. Fields are listed in offset order and there is no implicit
/// padding: every byte is a named field, so std::bit_cast and memcpy copy
/// defined values only.
struct alignas(8) Parcel {
  std::uint16_t schema_id = kSchemaId;  // offset  0
  std::uint16_t version = kVersion;     // offset  2
  std::uint32_t weight_g = 0;           // offset  4
  std::uint64_t seq = 0;                // offset  8
  std::int64_t intended_emit_ns = 0;    // offset 16
  std::int64_t actual_emit_ns = 0;      // offset 24
  std::uint64_t encoder_tick = 0;       // offset 32
  std::uint32_t length_mm = 0;          // offset 40
  std::uint32_t width_mm = 0;           // offset 44
  std::uint32_t height_mm = 0;          // offset 48
  std::uint32_t scan_confidence_permille = 0;  // offset 52
  std::array<char, kBarcodeLen> barcode{};     // offset 56, ASCII digits, no terminator
  std::array<std::byte, 6> reserved{};         // offset 74, zero on write
};

static_assert(std::is_trivially_copyable_v<Parcel> && std::is_standard_layout_v<Parcel>);
static_assert(sizeof(Parcel) == kSize && alignof(Parcel) == 8);
static_assert(offsetof(Parcel, schema_id) == 0);
static_assert(offsetof(Parcel, version) == 2);
static_assert(offsetof(Parcel, weight_g) == 4);
static_assert(offsetof(Parcel, seq) == 8);
static_assert(offsetof(Parcel, intended_emit_ns) == 16);
static_assert(offsetof(Parcel, actual_emit_ns) == 24);
static_assert(offsetof(Parcel, encoder_tick) == 32);
static_assert(offsetof(Parcel, length_mm) == 40);
static_assert(offsetof(Parcel, width_mm) == 44);
static_assert(offsetof(Parcel, height_mm) == 48);
static_assert(offsetof(Parcel, scan_confidence_permille) == 52);
static_assert(offsetof(Parcel, barcode) == 56);
static_assert(offsetof(Parcel, reserved) == 74);
// No hidden padding: the named fields add up to the whole record.
static_assert(2 + 2 + 4 + 8 * 4 + 4 * 4 + kBarcodeLen + 6 == kSize);

using Bytes = std::array<std::byte, kSize>;

/// The record as wire bytes. Writes the header constants and zeroes `reserved`,
/// whatever `p` holds, so a record cannot be emitted with a wrong header.
[[nodiscard]] constexpr Bytes encode(Parcel p) noexcept {
  p.schema_id = kSchemaId;
  p.version = kVersion;
  p.reserved = {};
  return std::bit_cast<Bytes>(p);
}

enum class DecodeError : std::uint8_t {
  wrong_size,           ///< Fewer than 4 header bytes, or not exactly kSize bytes for version 1.
  wrong_schema,         ///< schema_id is not kSchemaId.
  unsupported_version,  ///< version is not kVersion.
};

[[nodiscard]] constexpr std::string_view to_string(DecodeError e) noexcept {
  switch (e) {
    case DecodeError::wrong_size: return "wrong_size";
    case DecodeError::wrong_schema: return "wrong_schema";
    case DecodeError::unsupported_version: return "unsupported_version";
  }
  return "unknown";
}

/// The header rules, in order: 4 header bytes, then schema_id, then version, then the exact size
/// for that version. A later, larger version is therefore reported as `unsupported_version`, not
/// as a bad size. Reads the header with memcpy, so `bytes` needs no alignment.
[[nodiscard]] inline std::expected<void, DecodeError> check_header(std::span<const std::byte> bytes) noexcept {
  std::array<std::uint16_t, 2> header{};  // schema_id, version
  if (bytes.size() < sizeof header) return std::unexpected{DecodeError::wrong_size};
  std::memcpy(header.data(), bytes.data(), sizeof header);
  if (header[0] != kSchemaId) return std::unexpected{DecodeError::wrong_schema};
  if (header[1] != kVersion) return std::unexpected{DecodeError::unsupported_version};
  if (bytes.size() != kSize) return std::unexpected{DecodeError::wrong_size};
  return {};
}

/// Checks the header (see check_header), then copies the record out (memcpy into a trivially
/// copyable object: no alignment requirement on `bytes`, no aliasing question).
[[nodiscard]] inline std::expected<Parcel, DecodeError> decode(std::span<const std::byte> bytes) noexcept {
  if (const auto ok = check_header(bytes); !ok) return std::unexpected{ok.error()};
  Parcel p;
  std::memcpy(&p, bytes.data(), kSize);
  return p;
}

/// The barcode as text (18 ASCII digits).
[[nodiscard]] constexpr std::string_view barcode_view(const Parcel& p) noexcept {
  return {p.barcode.data(), p.barcode.size()};
}

}  // namespace lowlat::flat::parcel_v1
