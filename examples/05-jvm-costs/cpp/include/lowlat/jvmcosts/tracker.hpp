// The in-flight parcel tracker of the scan-to-divert path, light version (see ../../../../README.md).
//
// decide() is the pure decision (lane from scan confidence, dimensions and weight, plus the divert
// deadline in encoder ticks); Tracker::on_parcel() adds the barcode-keyed table of parcels between
// the scanner and the diverter. The same rules as the Java Tracker, so the two lanes do the same work.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "lowlat/line/v1/parcel.pb.h"

namespace lowlat::jvmcosts {

inline constexpr std::uint32_t kExceptionLane = 0;  ///< Unreadable scan: manual handling.
inline constexpr std::uint32_t kOversizeLane = 7;   ///< Oversize or overweight: manual chute.
inline constexpr std::uint32_t kSortLanes = 6;      ///< Lanes 1..6 are 1 kg weight classes.
inline constexpr std::int64_t kDivertTicks = 1'200; ///< 1.2 m at 1,000 encoder pulses per metre.

inline constexpr std::uint32_t kMinConfidencePermille = 900;
inline constexpr std::uint32_t kOversizeMm = 1'000;
inline constexpr std::uint32_t kOversizeG = 30'000;
inline constexpr std::uint32_t kWeightClassG = 1'000;

/// The decision for one parcel: the lane and the belt position by which the diverter must have acted.
struct Decision {
  std::uint32_t lane;
  std::int64_t deadline_tick;
  friend bool operator==(const Decision&, const Decision&) = default;
};

/// Pure and header-only, so a benchmark loop can inline it.
[[nodiscard]] inline Decision decide(const line::v1::ParcelEvent& ev) noexcept {
  const auto& dims = ev.dims();
  const std::uint32_t longest_mm = std::max({dims.length_mm(), dims.width_mm(), dims.height_mm()});
  std::uint32_t lane = 0;
  if (ev.scan_confidence_permille() < kMinConfidencePermille) {
    lane = kExceptionLane;
  } else if (longest_mm > kOversizeMm || ev.weight_g() > kOversizeG) {
    lane = kOversizeLane;
  } else {
    lane = 1 + std::min(kSortLanes - 1, ev.weight_g() / kWeightClassG);
  }
  return {.lane = lane, .deadline_tick = static_cast<std::int64_t>(ev.encoder_tick()) + kDivertTicks};
}

/// decide() plus the in-flight table: a barcode-keyed hash map, expired by encoder tick through a ring
/// of barcodes in arrival order.
///
/// on_parcel() allocates a hash node and an 18-character key (a copy of the barcode, in the map and
/// again in the ring) for every parcel. That is parity with the Java Tracker's HashMap<String, ...>,
/// not an allocation-free design: this consumer pays for the allocations the Java one does.
///
/// Barcodes are unique among in-flight parcels (an SSCC-18 is a serial number). If one arrived twice
/// before it expired, insert_or_assign would overwrite the table entry while the ring held two
/// copies of the key, and evicting the older copy would erase the newer parcel's entry early. The
/// tracker relies on the invariant and does not guard against a repeat, which keeps the hot path
/// free of an extra lookup.
class Tracker {
 public:
  Tracker() : ring_(kRing) { in_flight_.reserve(kRing); }

  [[nodiscard]] Decision on_parcel(const line::v1::ParcelEvent& ev) {
    const Decision decision = decide(ev);
    expire(static_cast<std::int64_t>(ev.encoder_tick()));
    if (size_ == kRing) evict_oldest();
    in_flight_.insert_or_assign(ev.barcode(), InFlight{.seq = ev.seq(), .lane = decision.lane,
                                                       .deadline_tick = decision.deadline_tick});
    ring_[(head_ + size_++) & kMask] = ev.barcode();
    return decision;
  }

  [[nodiscard]] std::size_t in_flight_count() const noexcept { return in_flight_.size(); }
  [[nodiscard]] bool is_in_flight(std::string_view barcode) const { return in_flight_.contains(barcode); }

 private:
  struct InFlight {
    std::uint64_t seq;
    std::uint32_t lane;
    std::int64_t deadline_tick;
  };

  static constexpr std::size_t kRing = 8192;  // a power of two, above the in-flight count at 1 kHz
  static constexpr std::size_t kMask = kRing - 1;

  void expire(std::int64_t tick) {
    while (size_ > 0) {
      const auto oldest = in_flight_.find(ring_[head_]);
      if (oldest != in_flight_.end() && oldest->second.deadline_tick > tick) return;
      evict_oldest();
    }
  }

  void evict_oldest() {
    in_flight_.erase(ring_[head_]);
    head_ = (head_ + 1) & kMask;
    --size_;
  }

  // Transparent lookup: is_in_flight() takes a string_view without building a std::string.
  struct StringHash {
    using is_transparent = void;
    [[nodiscard]] std::size_t operator()(std::string_view s) const noexcept { return std::hash<std::string_view>{}(s); }
  };

  std::unordered_map<std::string, InFlight, StringHash, std::equal_to<>> in_flight_;
  std::vector<std::string> ring_;  // barcodes, oldest at head_
  std::size_t head_ = 0;
  std::size_t size_ = 0;
};

}  // namespace lowlat::jvmcosts
