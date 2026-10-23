// The in-flight parcel table in two layouts, and the sweep that runs at every encoder tick.
//
//   std::vector<ParcelState>                       flat: one 24-byte struct per slot, contiguous.
//   std::vector<std::unique_ptr<ParcelState>>      pointers: one heap object per slot, the layout
//                                                  an array of Java objects has by default.
//
// C++ keeps the flat layout by default: a vector of structs is the idiomatic container, and the
// pointer layout is the one you have to ask for. The Java chapter shows what it takes to get the
// same layout on the JVM (a MemorySegment of structs); this is the contrast, not a language contest.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <type_traits>
#include <vector>

namespace lowlat::flat {

inline constexpr std::uint8_t kInFlight = 1;
inline constexpr std::uint8_t kDiverted = 2;

/// Same fields, same 24 bytes as the Java FlatTable struct and ParcelState record.
struct ParcelState {
  std::uint64_t seq = 0;
  std::uint64_t encoder_tick = 0;  ///< Belt position when the parcel was scanned.
  std::uint32_t weight_g = 0;
  std::uint8_t lane = 0;           ///< 0 to 7.
  std::uint8_t state = kInFlight;  ///< kInFlight or kDiverted.
  std::uint16_t reserved = 0;      ///< Named, so the record has no implicit padding.
};

static_assert(sizeof(ParcelState) == 24 && alignof(ParcelState) == 8);
static_assert(std::is_trivially_copyable_v<ParcelState> && std::is_standard_layout_v<ParcelState>);

/// In-flight parcels in slot order, plus the tick at which about 2 percent of them are due.
struct TableData {
  std::vector<ParcelState> by_slot;
  std::uint64_t due_tick = 0;
};

/// Deterministic parcels created in arrival order but stored at a shuffled slot (a hash would
/// pick it), so slot order is not allocation order.
[[nodiscard]] TableData make_table_data(std::size_t size, std::uint64_t seed);

/// The pointer layout of the same parcels: one heap object each, allocated in arrival order and
/// stored at the same slots as `data.by_slot`.
[[nodiscard]] std::vector<std::unique_ptr<ParcelState>> make_pointer_table(const TableData& data);

/// Total weight in grams of the in-flight parcels whose encoder_tick has reached `due_tick`: the
/// parcels the diverter must act on now. Reads encoder_tick of every slot; state and weight_g only for
/// the about 2 percent that are due (the && short-circuits).
[[nodiscard]] inline std::uint64_t sweep_due(std::span<const ParcelState> table, std::uint64_t due_tick) noexcept {
  std::uint64_t weight = 0;
  for (const ParcelState& p : table) {
    if (p.encoder_tick <= due_tick && p.state == kInFlight) weight += p.weight_g;
  }
  return weight;
}

[[nodiscard]] inline std::uint64_t sweep_due(std::span<const std::unique_ptr<ParcelState>> table,
                                             std::uint64_t due_tick) noexcept {
  std::uint64_t weight = 0;
  for (const auto& p : table) {
    if (p->encoder_tick <= due_tick && p->state == kInFlight) weight += p->weight_g;
  }
  return weight;
}

}  // namespace lowlat::flat
