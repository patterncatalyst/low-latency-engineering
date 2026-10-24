// Small helpers the Ch10 executables share for reports.
#pragma once

#include <hdr/hdr_histogram.h>

#include <cstdint>
#include <map>
#include <string>

#include "lowlat/measure/recorder.hpp"

namespace lowlat::lockfree {

/// Adds every sample of `from` to `into`, one record() per sample at the histogram's own
/// resolution (the kit's Recorder has no merge; the cost is paid after the run, off the hot path).
inline void merge_into(measure::Recorder& into, const measure::Recorder& from) {
  hdr_iter it;
  hdr_iter_recorded_init(&it, &from.histogram());
  while (hdr_iter_next(&it)) {
    for (std::int64_t i = 0; i < it.count; ++i) into.record(it.value);
  }
  into.add_dropped(from.dropped());
}

}  // namespace lowlat::lockfree
