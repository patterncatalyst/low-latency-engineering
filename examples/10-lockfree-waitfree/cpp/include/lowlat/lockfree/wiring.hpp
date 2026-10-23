// Build wiring for Ch10 (S4); replaced by the real claim variants in S6.
#pragma once

#include <atomic>
#include <cstdint>

namespace lowlat::lockfree {

// The wait-free claim step: one fetch_add.
class FetchAddClaim {
 public:
  std::uint64_t claim() noexcept { return next_.fetch_add(1, std::memory_order_relaxed); }

 private:
  std::atomic<std::uint64_t> next_{0};
};

}  // namespace lowlat::lockfree
