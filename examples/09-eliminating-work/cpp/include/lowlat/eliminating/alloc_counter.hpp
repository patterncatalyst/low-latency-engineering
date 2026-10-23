// Exact allocation counts for the current thread. Linking src/alloc_counter.cpp replaces the global
// allocation functions (the Ch5 pattern): every `new` on this thread bumps a thread-local counter, so a
// measured region reads the counter before and after and the difference is exact, with no sampling and no
// atomic on the allocation path.
#pragma once

#include <cstdint>

namespace lowlat::eliminating::alloc {

struct Snapshot {
  std::uint64_t allocations = 0;  ///< Calls to operator new on this thread.
  std::uint64_t bytes = 0;        ///< Bytes requested by those calls.
};

[[nodiscard]] Snapshot snapshot() noexcept;

[[nodiscard]] inline Snapshot since(const Snapshot& before) noexcept {
  const Snapshot now = snapshot();
  return {now.allocations - before.allocations, now.bytes - before.bytes};
}

}  // namespace lowlat::eliminating::alloc
