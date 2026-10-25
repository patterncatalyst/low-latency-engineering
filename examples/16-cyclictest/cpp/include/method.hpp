// The probe's parameters for the chapter's `method` lane, mirroring
//   cyclictest -m -p95 --policy=fifo --clock=monotonic -a 3 -i 1000
// except that the probe runs beside cyclictest on guest CPU 2 (the lane leaves CPU 3 to cyclictest).
#pragma once

#include <chrono>

#include "lowlat/cyclic/probe.hpp"

namespace lowlat::ch16 {

inline constexpr int kProbeCpu = 2;
inline constexpr int kFifoPriority = 95;
inline constexpr std::chrono::microseconds kInterval{1000};

[[nodiscard]] inline cyclic::Config method(std::chrono::seconds duration) {
  return {.cpu = kProbeCpu,
          .interval = kInterval,
          .duration = duration,
          .fifo_priority = kFifoPriority,
          .lock_memory = true};
}

}  // namespace lowlat::ch16
