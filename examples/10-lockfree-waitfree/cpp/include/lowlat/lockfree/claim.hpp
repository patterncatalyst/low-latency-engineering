// Three ways to hand out the next sequence number of a multi-producer log.
//
// The progress guarantee belongs to the operation, not to the structure:
//   MutexClaim     blocking     a producer that holds the lock and is descheduled stops every other
//   CasLoopClaim   lock-free    some producer always completes, but one can lose the race forever
//   FetchAddClaim  wait-free    one instruction (lock xadd on x86-64), every producer finishes in
//                               one step; on an LL/SC machine fetch_add is itself a retry loop
//
// A claim only hands out a unique number; the order in which data becomes visible is the log's job
// (claim_log.hpp). The sequence is 64 bits and strictly increasing, so a number is never reused:
// there is no ABA to defend against, and nothing is freed, so there is nothing to reclaim.
// (Structures that recycle nodes need hazard pointers or epochs; C++26's <hazard_pointer> and <rcu>
// are not shipped by GCC 16 or Clang 22 yet, see the README.)
#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <concepts>
#include <mutex>
#include <new>

namespace lowlat::lockfree {

/// One producer's counters. Each producer owns one, so counting costs no shared write.
/// Padded to two destructive-interference ranges: the L2 spatial prefetcher pulls line pairs.
struct alignas(2 * std::hardware_destructive_interference_size) ClaimStats {
  std::uint64_t claims = 0;
  std::uint64_t steps = 0;         ///< lock acquisitions, CAS attempts or fetch_adds executed
  std::uint64_t cas_failures = 0;  ///< failed compare_exchange attempts (CasLoopClaim only)
  std::uint64_t max_retries = 0;   ///< most failed attempts inside one claim
  std::uint64_t room_limit = 0;    ///< ClaimLog's cache of how far ahead of the consumer this producer may write
};

class MutexClaim {
 public:
  std::uint64_t claim(ClaimStats& stats) {
    const std::scoped_lock lock{mutex_};
    ++stats.claims;
    ++stats.steps;
    return next_++;
  }

 private:
  std::mutex mutex_;
  std::uint64_t next_ = 0;  // guarded by mutex_
};

class CasLoopClaim {
 public:
  std::uint64_t claim(ClaimStats& stats) noexcept {
    ++stats.claims;
    std::uint64_t seen = next_.load(std::memory_order_relaxed);
    std::uint64_t retries = 0;
    for (;;) {
      ++stats.steps;
      // On failure compare_exchange_weak reloads `seen`, so the loop body needs no second load.
      if (next_.compare_exchange_weak(seen, seen + 1, std::memory_order_relaxed)) break;
      ++stats.cas_failures;
      ++retries;
    }
    stats.max_retries = std::max(stats.max_retries, retries);
    return seen;
  }

 private:
  std::atomic<std::uint64_t> next_{0};
};

class FetchAddClaim {
 public:
  std::uint64_t claim(ClaimStats& stats) noexcept {
    ++stats.claims;
    ++stats.steps;
    return next_.fetch_add(1, std::memory_order_relaxed);
  }

 private:
  std::atomic<std::uint64_t> next_{0};
};

template <class C>
concept SequenceClaim = requires(C& c, ClaimStats& s) {
  { c.claim(s) } -> std::same_as<std::uint64_t>;
};

}  // namespace lowlat::lockfree
