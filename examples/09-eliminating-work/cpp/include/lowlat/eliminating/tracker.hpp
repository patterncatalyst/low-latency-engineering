// The in-flight parcel tracker, barcode -> parcel state, in the two shapes Ch9 compares.
//
//   NodeTracker  std::unordered_map<std::string, FatRecord>: the idiomatic default. The 18-digit key is
//                longer than libstdc++'s 15-character small-string buffer, so every insert allocates
//                twice (the node, then the key's characters), and a lookup chases bucket -> node ->
//                key characters.
//   FlatTracker  absl::flat_hash_map<std::uint64_t, std::uint32_t> from the packed SSCC to a slot, plus
//                the record table (columns or rows). reserve()d once: an insert allocates nothing.
//
// Both: track (insert or re-scan), erase, find_state, sweep_due (read-only count of parcels due at a
// tick), expire (erase what is due).
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <unordered_map>

#include "absl/container/flat_hash_map.h"
#include "lowlat/eliminating/keys.hpp"
#include "lowlat/eliminating/records.hpp"
#include "lowlat/eliminating/sscc.hpp"

namespace lowlat::eliminating {

enum class Tracked { inserted, updated, rejected };

/// Transparent hash, so find() takes a std::string_view without building a std::string.
struct StringHash {
  using is_transparent = void;
  [[nodiscard]] std::size_t operator()(std::string_view s) const noexcept { return std::hash<std::string_view>{}(s); }
};

class NodeTracker {
 public:
  explicit NodeTracker(std::size_t expected) { map_.reserve(expected); }

  Tracked track(const Scan& scan) {
    const auto sscc = pack_sscc(scan.barcode);
    if (!sscc) return Tracked::rejected;
    if (const auto it = map_.find(scan.barcode); it != map_.end()) {
      rescan(it->second, scan);
      return Tracked::updated;
    }
    map_.emplace(std::string{scan.barcode}, make_record(scan, *sscc));
    return Tracked::inserted;
  }

  bool erase(std::string_view barcode) {
    const auto it = map_.find(barcode);
    if (it == map_.end()) return false;
    map_.erase(it);
    return true;
  }

  [[nodiscard]] State find_state(std::string_view barcode) const noexcept {
    const auto it = map_.find(barcode);
    return it == map_.end() ? State::empty : it->second.state;
  }

  [[nodiscard]] std::size_t sweep_due(std::uint64_t tick) const noexcept {
    std::size_t due = 0;
    for (const auto& [key, r] : map_) due += (r.state == State::in_flight) & (r.due_tick <= tick);
    return due;
  }

  std::size_t expire(std::uint64_t tick) {
    return std::erase_if(map_, [tick](const auto& node) {
      return node.second.state == State::in_flight && node.second.due_tick <= tick;
    });
  }

  [[nodiscard]] std::size_t size() const noexcept { return map_.size(); }

  /// The key a lookup into this tracker uses.
  [[nodiscard]] static std::string_view lookup_key(const Keys& keys, std::size_t i) noexcept { return keys.text[i]; }

 private:
  std::unordered_map<std::string, FatRecord, StringHash, std::equal_to<>> map_;
};

template <class Table>
class FlatTracker {
 public:
  explicit FlatTracker(std::size_t expected) {
    index_.reserve(expected);
    table_.reserve(expected);
  }

  Tracked track(const Scan& scan) {
    const auto sscc = pack_sscc(scan.barcode);
    if (!sscc) return Tracked::rejected;
    const auto [it, fresh] = index_.try_emplace(*sscc, 0U);  // one probe for both outcomes
    if (fresh) {
      it->second = table_.insert(make_record(scan, *sscc));
      return Tracked::inserted;
    }
    table_.rescan_slot(it->second, scan);
    return Tracked::updated;
  }

  bool erase(std::string_view barcode) {
    const auto sscc = pack_sscc(barcode);
    return sscc && erase_key(*sscc);
  }

  bool erase_key(std::uint64_t sscc) {
    const auto it = index_.find(sscc);
    if (it == index_.end()) return false;
    table_.erase(it->second);
    index_.erase(it);
    return true;
  }

  [[nodiscard]] State find_state(std::string_view barcode) const noexcept {
    const auto sscc = pack_sscc(barcode);
    return sscc ? find_state(*sscc) : State::empty;
  }

  [[nodiscard]] State find_state(std::uint64_t sscc) const noexcept {
    const auto it = index_.find(sscc);
    return it == index_.end() ? State::empty : table_.state(it->second);
  }

  [[nodiscard]] std::size_t sweep_due(std::uint64_t tick) const noexcept { return table_.sweep_due(tick); }

  std::size_t expire(std::uint64_t tick) {
    std::size_t erased = 0;
    for (std::uint32_t slot = 0; slot < table_.slots(); ++slot) {
      if (table_.state(slot) == State::in_flight && table_.due_tick(slot) <= tick) {
        erased += erase_key(table_.key(slot));
      }
    }
    return erased;
  }

  [[nodiscard]] std::size_t size() const noexcept { return index_.size(); }

  [[nodiscard]] static std::uint64_t lookup_key(const Keys& keys, std::size_t i) noexcept { return keys.packed[i]; }

 private:
  absl::flat_hash_map<std::uint64_t, std::uint32_t> index_;
  Table table_;
};

/// The flat tracker of the chapter: open addressing for the key, hot/cold columns for the record.
using HotColdTracker = FlatTracker<HotColdTable>;

}  // namespace lowlat::eliminating
