// The parcel stream of the micro workloads: a std::generator of ParcelEvents, produced lazily.
// The line run receives the same message type from the simulator's UDP feed instead.
#pragma once

#include <cstdint>
#include <format>
#include <generator>

#include "lowlat/line/v1/parcel.pb.h"

namespace lowlat::tasks {

/// `count` parcels numbered from 0: an 18-digit SSCC barcode derived from the sequence, the encoder tick,
/// and an intended emit time that starts at `first_intended_ns` and advances by `step_ns` per parcel.
inline std::generator<line::v1::ParcelEvent> parcels(std::uint64_t count, std::int64_t first_intended_ns = 0,
                                                      std::int64_t step_ns = 100'000) {
  for (std::uint64_t seq = 0; seq < count; ++seq) {
    line::v1::ParcelEvent ev;
    ev.set_seq(seq);
    ev.set_intended_emit_ns(first_intended_ns + static_cast<std::int64_t>(seq) * step_ns);
    ev.set_encoder_tick(seq);
    ev.set_barcode(std::format("{:018}", 300'000'000'000'000'000ULL + seq));
    ev.set_scan_confidence_permille(seq % 20 == 0 ? 400 : 990);
    co_yield ev;
  }
}

}  // namespace lowlat::tasks
