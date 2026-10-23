// The parcel record and the two ways to lay it out for the per-tick due sweep.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <vector>

namespace lowlat::eliminating {

enum class State : std::uint8_t { empty = 0, in_flight = 1, diverted = 2 };

/// Encoder ticks between the scanner and the diverter: 1.2 m at 1000 pulses per metre (the line's
/// defaults), so a parcel scanned at tick t is due at the diverter at t + 1200.
inline constexpr std::uint64_t kDivertTicks = 1200;

/// One scan of one parcel, as the tracker receives it.
struct Scan {
  std::string_view barcode;  ///< 18 ASCII digits (SSCC-18).
  std::uint64_t seq = 0;
  std::uint64_t tick = 0;  ///< Encoder tick at the scanner.
  std::uint32_t weight_g = 0;
  std::uint16_t length_mm = 0;
  std::uint16_t width_mm = 0;
  std::uint16_t height_mm = 0;
  std::uint16_t confidence_permille = 0;
};

/// Everything the tracker knows about a parcel, in one struct: the layout a first draft has.
/// The sweep reads `due_tick` and `state` (9 of the 80 bytes) and drags the other 71 through the
/// cache with them.
struct FatRecord {
  std::uint64_t sscc = 0;  ///< Packed SSCC-18.
  std::uint64_t due_tick = 0;
  std::uint64_t scan_tick = 0;
  std::uint64_t seq = 0;
  std::uint64_t divert_tick = 0;
  std::uint32_t weight_g = 0;
  std::uint16_t length_mm = 0;
  std::uint16_t width_mm = 0;
  std::uint16_t height_mm = 0;
  std::uint16_t confidence_permille = 0;
  State state = State::empty;
  std::uint8_t lane = 0;
  std::array<char, 26> destination{};  ///< Sort-plan code the diverter decision will use.
};
static_assert(sizeof(FatRecord) == 80, "the fat record is meant to be 80 bytes");

/// The fields the sweep never reads (everything but `due_tick` and `state`).
struct ColdFields {
  std::uint64_t sscc = 0;
  std::uint64_t scan_tick = 0;
  std::uint64_t seq = 0;
  std::uint64_t divert_tick = 0;
  std::uint32_t weight_g = 0;
  std::uint16_t length_mm = 0;
  std::uint16_t width_mm = 0;
  std::uint16_t height_mm = 0;
  std::uint16_t confidence_permille = 0;
  std::uint8_t lane = 0;
  std::array<char, 26> destination{};
};

[[nodiscard]] inline FatRecord make_record(const Scan& scan, std::uint64_t sscc) noexcept {
  FatRecord r;
  r.sscc = sscc;
  r.due_tick = scan.tick + kDivertTicks;
  r.scan_tick = scan.tick;
  r.seq = scan.seq;
  r.weight_g = scan.weight_g;
  r.length_mm = scan.length_mm;
  r.width_mm = scan.width_mm;
  r.height_mm = scan.height_mm;
  r.confidence_permille = scan.confidence_permille;
  r.state = State::in_flight;
  r.lane = static_cast<std::uint8_t>(sscc % 8);
  return r;
}

/// Overwrites what a re-scan changes (the reading and the due tick) and keeps the rest.
inline void rescan(FatRecord& r, const Scan& scan) noexcept {
  r.due_tick = scan.tick + kDivertTicks;
  r.scan_tick = scan.tick;
  r.confidence_permille = scan.confidence_permille;
}

/// 1 when an in-flight parcel is due at `tick`. Bitwise on ints on purpose: the sweep stays free of
/// data-dependent branches, so its time is the memory it reads, not the branch predictor.
[[nodiscard]] constexpr int is_due(State state, std::uint64_t due_tick, std::uint64_t tick) noexcept {
  return static_cast<int>(state == State::in_flight) & static_cast<int>(due_tick <= tick);
}

/// Array of structs: slot i is one 80-byte record. `sweep_due` walks 80 bytes per slot.
class FatTable {
 public:
  void reserve(std::size_t n) {
    rows_.reserve(n);
    free_.reserve(n);  // the free list never allocates after this, so an insert never does either
  }
  [[nodiscard]] std::size_t slots() const noexcept { return rows_.size(); }

  [[nodiscard]] std::uint32_t insert(const FatRecord& r) {
    if (!free_.empty()) {
      const std::uint32_t slot = free_.back();
      free_.pop_back();
      rows_[slot] = r;
      return slot;
    }
    rows_.push_back(r);
    return static_cast<std::uint32_t>(rows_.size() - 1);
  }
  void rescan_slot(std::uint32_t slot, const Scan& scan) noexcept { rescan(rows_[slot], scan); }
  void erase(std::uint32_t slot) {
    rows_[slot].state = State::empty;
    free_.push_back(slot);
  }
  [[nodiscard]] State state(std::uint32_t slot) const noexcept { return rows_[slot].state; }
  [[nodiscard]] std::uint64_t key(std::uint32_t slot) const noexcept { return rows_[slot].sscc; }
  [[nodiscard]] std::uint64_t due_tick(std::uint32_t slot) const noexcept { return rows_[slot].due_tick; }

  /// In-flight parcels due at `tick` or earlier.
  [[nodiscard]] std::size_t sweep_due(std::uint64_t tick) const noexcept {
    std::size_t due = 0;
    for (const FatRecord& r : rows_) due += is_due(r.state, r.due_tick, tick);
    return due;
  }

 private:
  std::vector<FatRecord> rows_;
  std::vector<std::uint32_t> free_;
};

/// Struct of arrays: the sweep's two fields in their own contiguous columns (9 bytes per slot),
/// everything else in a cold column the sweep never touches.
class HotColdTable {
 public:
  void reserve(std::size_t n) {
    due_.reserve(n);
    state_.reserve(n);
    cold_.reserve(n);
    free_.reserve(n);
  }
  [[nodiscard]] std::size_t slots() const noexcept { return state_.size(); }

  [[nodiscard]] std::uint32_t insert(const FatRecord& r) {
    const ColdFields cold{r.sscc,   r.scan_tick, r.seq,       r.divert_tick,         r.weight_g,
                          r.length_mm, r.width_mm, r.height_mm, r.confidence_permille, r.lane,
                          r.destination};
    if (!free_.empty()) {
      const std::uint32_t slot = free_.back();
      free_.pop_back();
      due_[slot] = r.due_tick;
      state_[slot] = r.state;
      cold_[slot] = cold;
      return slot;
    }
    due_.push_back(r.due_tick);
    state_.push_back(r.state);
    cold_.push_back(cold);
    return static_cast<std::uint32_t>(state_.size() - 1);
  }
  void rescan_slot(std::uint32_t slot, const Scan& scan) noexcept {
    due_[slot] = scan.tick + kDivertTicks;
    cold_[slot].scan_tick = scan.tick;
    cold_[slot].confidence_permille = scan.confidence_permille;
  }
  void erase(std::uint32_t slot) {
    state_[slot] = State::empty;
    free_.push_back(slot);
  }
  [[nodiscard]] State state(std::uint32_t slot) const noexcept { return state_[slot]; }
  [[nodiscard]] std::uint64_t key(std::uint32_t slot) const noexcept { return cold_[slot].sscc; }
  [[nodiscard]] std::uint64_t due_tick(std::uint32_t slot) const noexcept { return due_[slot]; }

  [[nodiscard]] std::size_t sweep_due(std::uint64_t tick) const noexcept {
    std::size_t due = 0;
    for (std::size_t i = 0; i < state_.size(); ++i) due += is_due(state_[i], due_[i], tick);
    return due;
  }

 private:
  std::vector<std::uint64_t> due_;
  std::vector<State> state_;
  std::vector<ColdFields> cold_;
  std::vector<std::uint32_t> free_;
};

}  // namespace lowlat::eliminating
