#include "lowlat/flat/table.hpp"

#include <algorithm>
#include <numeric>
#include <random>

namespace lowlat::flat {

namespace {
constexpr double kDueFraction = 0.02;  // the few parcels at the diverter
}

TableData make_table_data(std::size_t size, std::uint64_t seed) {
  std::mt19937_64 rng{seed};
  std::vector<std::size_t> slot_of(size);
  std::iota(slot_of.begin(), slot_of.end(), std::size_t{0});
  std::ranges::shuffle(slot_of, rng);

  TableData data;
  data.by_slot.resize(size);
  std::uniform_int_distribution<std::uint32_t> weight{100, 29'999};
  std::uniform_int_distribution<int> lane{0, 7};
  std::uniform_int_distribution<int> diverted{0, 9};
  for (std::size_t arrival = 0; arrival < size; ++arrival) {
    data.by_slot[slot_of[arrival]] = ParcelState{
        .seq = arrival,
        .encoder_tick = arrival / 4,  // 2,500 pulses/s at 10 kHz
        .weight_g = weight(rng),
        .lane = static_cast<std::uint8_t>(lane(rng)),
        .state = diverted(rng) == 0 ? kDiverted : kInFlight,
    };
  }
  data.due_tick = static_cast<std::uint64_t>(static_cast<double>(size) * kDueFraction) / 4;
  return data;
}

std::vector<std::unique_ptr<ParcelState>> make_pointer_table(const TableData& data) {
  const std::size_t size = data.by_slot.size();
  // Allocate in arrival order (seq), place by slot: the same scatter as the Java object table.
  std::vector<std::size_t> slot_of_seq(size);
  for (std::size_t slot = 0; slot < size; ++slot) slot_of_seq[data.by_slot[slot].seq] = slot;
  std::vector<std::unique_ptr<ParcelState>> table(size);
  for (std::size_t seq = 0; seq < size; ++seq) {
    table[slot_of_seq[seq]] = std::make_unique<ParcelState>(data.by_slot[slot_of_seq[seq]]);
  }
  return table;
}

}  // namespace lowlat::flat
