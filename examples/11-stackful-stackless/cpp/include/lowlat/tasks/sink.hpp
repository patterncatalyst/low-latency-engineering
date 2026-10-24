// An observable side effect for the bench loops. The definition lives in another translation unit and
// the store is atomic, so the compiler cannot prove a loop's result unused and delete the loop (r03:
// every bench loop ends in an external-linkage sink or benchmark::DoNotOptimize).
#pragma once

#include <cstdint>

namespace lowlat::tasks {

/// Adds `value` to a counter with external linkage. Call it with something the loop computed.
void sink(std::uint64_t value) noexcept;

/// What the sink holds so far (a test and the benches print it).
[[nodiscard]] std::uint64_t sink_value() noexcept;

}  // namespace lowlat::tasks
