// A single-producer single-consumer ring over std::atomic indices (Ch7 C++ lane).
//
// Two indices, each written by one thread only. The producer publishes a slot with a release
// store of `tail_`; the consumer sees it with an acquire load and frees it with a release store
// of `head_`, which the producer acquires before it reuses the slot. That pairing is all the
// ordering the structure needs: no lock, no compare-and-swap, no sequentially consistent store.
//
// Each index sits in its own false-sharing range (two destructive-interference sizes, 128 bytes
// on x86-64), next to the other thread's cached copy of it, so the producer's stores never
// invalidate the line the consumer is spinning on. Without the alignment the two indices share a
// line and every push and every pop bounces it between the cores. The range is twice the
// cache-line size because the L2 spatial prefetcher on recent Intel cores fetches the adjacent
// line of a 128-byte pair; Folly and crossbeam pad to 128 on x86-64 for the same reason.
//
// The indices are 32 bits and wrap: libstdc++ implements atomic::wait/notify on a futex only for
// 4-byte types; a 64-bit atomic goes through a shared table of proxy waiters.
#pragma once

#include <array>
#include <atomic>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <new>
#include <optional>
#include <type_traits>

namespace lowlat::offheap {

// GCC warns (-Winterference-size) that this value is not ABI-stable across compiler flags; the
// ring is header-only and never crosses a build, so the warning is switched off for the project.
inline constexpr std::size_t kFalseSharingRange = 2 * std::hardware_destructive_interference_size;

template <class T, std::size_t Capacity>
class SpscRing {
  using Index = std::uint32_t;  // wraps modulo 2^32; differences stay correct for Capacity <= 2^31

  static_assert(std::has_single_bit(Capacity), "capacity must be a power of two so the index wraps with a mask");
  static_assert(Capacity <= (std::size_t{1} << 31), "32-bit indices: full is tail - head == Capacity");
  static_assert(std::is_trivially_copyable_v<T>, "slots are copied by value on both threads");
  static_assert(std::atomic<Index>::is_always_lock_free && sizeof(Index) == 4,
                "the index must be a 4-byte lock-free atomic so wait/notify use a futex directly");

 public:
  /// Producer only. False when the ring is full: the caller decides what that means.
  [[nodiscard]] bool try_push(const T& value) noexcept {
    const Index tail = tail_.load(std::memory_order_relaxed);  // ours: no ordering needed
    if (tail - cached_head_ == Capacity) {
      cached_head_ = head_.load(std::memory_order_acquire);  // the consumer's frees, now visible
      if (tail - cached_head_ == Capacity) return false;
    }
    slots_[tail & kMask] = value;
    tail_.store(tail + 1, std::memory_order_release);  // publishes the slot write above
    return true;
  }

  /// Consumer only. Empty optional when the ring is empty.
  [[nodiscard]] std::optional<T> try_pop() noexcept {
    const Index head = head_.load(std::memory_order_relaxed);
    if (head == cached_tail_) {
      cached_tail_ = tail_.load(std::memory_order_acquire);  // the producer's slot writes, now visible
      if (head == cached_tail_) return std::nullopt;
    }
    T value = slots_[head & kMask];
    head_.store(head + 1, std::memory_order_release);  // frees the slot for the producer
    return value;
  }

  /// Producer only: wake a consumer parked in wait_for_data(). The wake-up costs a system call
  /// when a consumer is parked and is a cheap check when none is.
  void notify_consumer() noexcept { tail_.notify_one(); }

  /// Consumer only: block until the producer has published something, without spinning. The wait
  /// parks the thread in the kernel on a futex (the index is a 4-byte atomic) once the library's
  /// short user-space spin is over.
  void wait_for_data() noexcept {
    const Index head = head_.load(std::memory_order_relaxed);
    const Index tail = tail_.load(std::memory_order_acquire);
    if (tail == head) tail_.wait(tail, std::memory_order_acquire);  // returns once tail_ != tail
  }

  /// True when the producer-written and consumer-written indices are in different false-sharing ranges.
  [[nodiscard]] static constexpr bool indices_on_separate_lines() noexcept {
    return offsetof(SpscRing, tail_) / kFalseSharingRange != offsetof(SpscRing, head_) / kFalseSharingRange;
  }

 private:
  static constexpr Index kMask = static_cast<Index>(Capacity - 1);

  alignas(kFalseSharingRange) std::atomic<Index> tail_{0};  // written by the producer
  Index cached_head_ = 0;                                   // producer's last look at head_
  alignas(kFalseSharingRange) std::atomic<Index> head_{0};  // written by the consumer
  Index cached_tail_ = 0;                                   // consumer's last look at tail_
  alignas(kFalseSharingRange) std::array<T, Capacity> slots_{};
};

}  // namespace lowlat::offheap
