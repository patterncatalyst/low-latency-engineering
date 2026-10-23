// A multi-producer, single-consumer log: producers claim a sequence number, write the slot, then
// publish it; the consumer reads the slots in sequence order.
//
// Publication is a release store of `seq + 1` into the slot's stamp, and the consumer's acquire load
// of the stamp is what makes the payload visible, so the payload itself is plain data. A producer
// never writes more than `capacity` slots ahead of the consumer (the log is a ring).
//
// Claiming a number and publishing it are two steps. The claim can be wait-free (FetchAddClaim) and
// the consumer still waits at a claimed-but-unpublished sequence for as long as its producer is
// stalled: the guarantee belongs to the claim operation, not to the log.
#pragma once

#include <atomic>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <type_traits>

#include "lowlat/lockfree/claim.hpp"
#include "lowlat/line/clock.hpp"

#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#endif

namespace lowlat::lockfree {

/// The spin-wait hint: PAUSE on x86, otherwise nothing.
inline void cpu_relax() noexcept {
#if defined(__x86_64__) || defined(__i386__)
  _mm_pause();
#endif
}

template <SequenceClaim Claim, class Payload>
  requires std::is_trivially_copyable_v<Payload>
class ClaimLog {
 public:
  explicit ClaimLog(std::size_t capacity) : mask_{capacity - 1}, slots_{std::make_unique<Slot[]>(capacity)} {
    if (!std::has_single_bit(capacity)) throw std::invalid_argument("ClaimLog capacity must be a power of two");
  }

  [[nodiscard]] std::size_t capacity() const noexcept { return mask_ + 1; }

  /// Producer: the next sequence number (the progress guarantee is Claim's).
  [[nodiscard]] std::uint64_t claim(ClaimStats& stats) { return claim_.claim(stats); }

  // The waits in publish() and read() are busy-spins with a PAUSE hint, not std::atomic::wait. A futex
  // wait and wake costs microseconds of system call and wake-up latency on a path whose claim takes
  // nanoseconds. The producer and consumer threads are pinned to cores of their own, so a spin burns
  // only their own CPU. It is a latency construct, not advice for general code (see the README).

  /// Producer: waits until the ring has room for `seq`, writes the payload and publishes the slot.
  void publish(std::uint64_t seq, const Payload& payload, ClaimStats& stats) noexcept {
    while (seq >= stats.room_limit) {
      stats.room_limit = consumed_.load(std::memory_order_acquire) + capacity();
      if (seq >= stats.room_limit) cpu_relax();
    }
    Slot& slot = slots_[seq & mask_];
    slot.payload = payload;
    slot.stamp.store(seq + 1, std::memory_order_release);
  }

  /// Consumer: waits until `seq` is published and returns its payload. `waited_ns` is 0 when the
  /// slot was already there, otherwise the time from the first miss to the publication.
  Payload read(std::uint64_t seq, std::int64_t& waited_ns) noexcept {
    const Slot& slot = slots_[seq & mask_];
    waited_ns = 0;
    if (slot.stamp.load(std::memory_order_acquire) != seq + 1) {
      const std::int64_t missed_at = line::monotonic_ns();
      while (slot.stamp.load(std::memory_order_acquire) != seq + 1) cpu_relax();
      waited_ns = line::monotonic_ns() - missed_at;
    }
    return slot.payload;
  }

  /// Consumer: hands the slot back to the producers.
  void consumed(std::uint64_t seq) noexcept { consumed_.store(seq + 1, std::memory_order_release); }

 private:
  struct Slot {
    std::atomic<std::uint64_t> stamp{0};
    Payload payload{};
  };

  static constexpr std::size_t kRange = 2 * std::hardware_destructive_interference_size;

  const std::size_t mask_;
  std::unique_ptr<Slot[]> slots_;
  alignas(kRange) Claim claim_;                              // written by every producer
  alignas(kRange) std::atomic<std::uint64_t> consumed_{0};   // written by the consumer
};

}  // namespace lowlat::lockfree
