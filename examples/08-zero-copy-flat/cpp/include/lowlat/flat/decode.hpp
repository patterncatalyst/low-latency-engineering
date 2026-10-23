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
// A fourth way is not provided: reinterpret_cast<const Parcel*>(buffer) and read through it.
// No Parcel object exists in that storage, so the read has undefined behaviour (it violates the
// object-lifetime and strict-aliasing rules, and a misaligned buffer adds an alignment violation).
// It often "works", because the compiler emits the loads one would expect, and that is the danger:
// an optimizer may assume no Parcel is read from storage that was written as bytes and reorder or
// drop the access. A number measured on code with undefined behaviour does not tell the reader what
// the code costs, only what one compiler did with it, so the chapter measures only the variants whose
// meaning the language defines. std::start_lifetime_as (C++23) is the sanctioned way to say "these
// bytes already are a Parcel".
//
// libstdc++ implements start_lifetime_as as a compiler barrier (an empty asm statement with a
// memory operand), so the compiler cannot reuse earlier loads or defer earlier stores across it.
// That barrier is part of the cost the chapter measures for the view.
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

/// The contract's decode: memcpy into a trivially copyable Parcel.
[[nodiscard]] inline std::expected<p1::Parcel, p1::DecodeError> decode_memcpy(std::span<const std::byte> bytes) noexcept {
  return p1::decode(bytes);
}

/// The same copy through std::bit_cast.
[[nodiscard]] inline std::expected<p1::Parcel, p1::DecodeError> decode_bit_cast(std::span<const std::byte> bytes) noexcept {
  if (auto ok = p1::check_header(bytes); !ok) return std::unexpected{ok.error()};
  std::array<std::byte, p1::kSize> raw;  // filled completely by the next line
  std::ranges::copy(bytes, raw.begin());
  return std::bit_cast<p1::Parcel>(raw);
}

/// The view's error for a failed header check, mapped case by case.
[[nodiscard]] constexpr ViewError to_view_error(p1::DecodeError e) noexcept {
  switch (e) {
    case p1::DecodeError::wrong_size: return ViewError::wrong_size;
    case p1::DecodeError::wrong_schema: return ViewError::wrong_schema;
    case p1::DecodeError::unsupported_version: return ViewError::unsupported_version;
  }
  return ViewError::wrong_size;  // unreachable for a valid DecodeError
}

/// No copy: the pointer addresses the received bytes. The object's lifetime ends when those bytes
/// are overwritten (the next recv into the same buffer, say) or when another start_lifetime_as
/// begins an object over overlapping storage; the pointer must not be used after either. The
/// storage must not be a const complete object of static or automatic storage duration. The buffer
/// must be aligned for Parcel (an `alignas(8)` receive buffer is; a UDP payload at an arbitrary
/// offset is not).
[[nodiscard]] inline std::expected<const p1::Parcel*, ViewError> view_start_lifetime_as(
    std::span<const std::byte> bytes) noexcept {
  if (const auto ok = p1::check_header(bytes); !ok) return std::unexpected{to_view_error(ok.error())};
  if (std::bit_cast<std::uintptr_t>(bytes.data()) % alignof(p1::Parcel) != 0) {
    return std::unexpected{ViewError::misaligned};
  }
  return std::start_lifetime_as<p1::Parcel>(bytes.data());
}

}  // namespace lowlat::flat
