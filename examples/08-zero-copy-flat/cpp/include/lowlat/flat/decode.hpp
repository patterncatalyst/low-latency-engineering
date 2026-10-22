// Three ways to read one parcel-v1 record out of a received buffer (std::span<const std::byte>).
//
//   decode_memcpy             memcpy into a Parcel (the contract's own decode()). Always correct:
//                             no alignment requirement on the buffer, no aliasing question.
//   decode_bit_cast           copy into a std::array<std::byte, 80>, then std::bit_cast<Parcel>.
//                             The same copy, spelled as a value conversion; needs no alignment either.
//   view_start_lifetime_as    std::start_lifetime_as<Parcel>(p): no copy. It begins the lifetime of
//                             a Parcel in the bytes that are already there and returns a pointer to
//                             it. The buffer must be aligned for Parcel (8 bytes) and the bytes must
//                             be a valid record, which the header check establishes.
//
// A fourth way is deliberately absent: reinterpret_cast<const Parcel*>(buffer) and read through it.
// No Parcel object exists in that storage, so the read has undefined behaviour (it violates the
// object-lifetime and strict-aliasing rules, and a misaligned buffer adds an alignment violation).
// It often "works", because the compiler emits the loads one would expect, and that is the danger:
// an optimizer may assume no Parcel is read from storage that was written as bytes and reorder or
// drop the access. A number measured on code with undefined behaviour does not tell the reader what
// the code costs, only what one compiler did with it, so the chapter measures only the variants whose
// meaning the language defines. std::start_lifetime_as (C++23) is the sanctioned way to say "these
// bytes already are a Parcel".
#pragma once

#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <expected>
#include <memory>
#include <span>

#include "parcel-v1/parcel_v1.hpp"

namespace lowlat::flat {

namespace p1 = parcel_v1;

/// Why a record could not be read as a view.
enum class ViewError : std::uint8_t {
  wrong_size,
  wrong_schema,
  unsupported_version,
  misaligned,  ///< The buffer is not aligned for Parcel; a copying decode would still work.
};

/// The header rules of the contract, in its order: 4 header bytes, then schema_id, then version,
/// then the exact size for that version. A later and larger version is "unsupported", not a bad size.
[[nodiscard]] inline std::expected<void, p1::DecodeError> check_header(std::span<const std::byte> bytes) noexcept {
  std::array<std::uint16_t, 2> header{};  // schema_id, version
  if (bytes.size() < sizeof header) return std::unexpected{p1::DecodeError::wrong_size};
  std::memcpy(header.data(), bytes.data(), sizeof header);
  if (header[0] != p1::kSchemaId) return std::unexpected{p1::DecodeError::wrong_schema};
  if (header[1] != p1::kVersion) return std::unexpected{p1::DecodeError::unsupported_version};
  if (bytes.size() != p1::kSize) return std::unexpected{p1::DecodeError::wrong_size};
  return {};
}

/// The contract's decode: memcpy into a trivially copyable Parcel.
[[nodiscard]] inline std::expected<p1::Parcel, p1::DecodeError> decode_memcpy(std::span<const std::byte> bytes) noexcept {
  return p1::decode(bytes);
}

/// The same copy through std::bit_cast.
[[nodiscard]] inline std::expected<p1::Parcel, p1::DecodeError> decode_bit_cast(std::span<const std::byte> bytes) noexcept {
  if (auto ok = check_header(bytes); !ok) return std::unexpected{ok.error()};
  std::array<std::byte, p1::kSize> raw;  // filled completely by the next line
  std::ranges::copy(bytes, raw.begin());
  return std::bit_cast<p1::Parcel>(raw);
}

/// No copy: the pointer addresses the received bytes, valid as long as they are. The buffer must
/// be aligned for Parcel (an `alignas(8)` receive buffer is; a UDP payload at an arbitrary offset is not).
[[nodiscard]] inline std::expected<const p1::Parcel*, ViewError> view_start_lifetime_as(
    std::span<const std::byte> bytes) noexcept {
  if (auto ok = check_header(bytes); !ok) {
    switch (ok.error()) {
      case p1::DecodeError::wrong_schema: return std::unexpected{ViewError::wrong_schema};
      case p1::DecodeError::unsupported_version: return std::unexpected{ViewError::unsupported_version};
      case p1::DecodeError::wrong_size: return std::unexpected{ViewError::wrong_size};
    }
  }
  if (std::bit_cast<std::uintptr_t>(bytes.data()) % alignof(p1::Parcel) != 0) {
    return std::unexpected{ViewError::misaligned};
  }
  return std::start_lifetime_as<p1::Parcel>(bytes.data());
}

}  // namespace lowlat::flat
