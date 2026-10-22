// A single-producer single-consumer ring over std::atomic indices (Ch7 C++ lane).
//
// Two indices, each written by one thread only. The producer publishes a slot with a release
// store of `tail_`; the consumer sees it with an acquire load and frees it with a release store
// of `head_`, which the producer acquires before it reuses the slot. That pairing is all the
// ordering the structure needs: no lock, no compare-and-swap, no sequentially consistent store.
//
// Each index sits on its own cache line (std::hardware_destructive_interference_size), next to
// the other thread's cached copy of it, so the producer's stores never invalidate the line the
// consumer is spinning on. Without the alignment the two indices share a line and every push and
// every pop bounces it between the cores.
#pragma once

#include <array>
#include <atomic>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <new>
#include <optional>

namespace lowlat::offheap {

inline constexpr std::size_t kCacheLine = std::hardware_destructive_interference_size;

template <class T, std::size_t Capacity>
class SpscRing {
  static_assert(std::has_single_bit(Capacity), "capacity must be a power of two so the index wraps with a mask");
  static_assert(std::atomic<std::uint64_t>::is_always_lock_free);

 public:
  /// Producer only. False when the ring is full: the caller decides what that means.
  [[nodiscard]] bool try_push(const T& value) noexcept {
    const std::uint64_t tail = tail_.load(std::memory_order_relaxed);  // ours: no ordering needed
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
    const std::uint64_t head = head_.load(std::memory_order_relaxed);
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
  /// parks the thread in the kernel (a futex) once its short user-space spin is over.
  void wait_for_data() noexcept {
    const std::uint64_t head = head_.load(std::memory_order_relaxed);
    const std::uint64_t tail = tail_.load(std::memory_order_acquire);
    if (tail == head) tail_.wait(tail, std::memory_order_acquire);  // returns once tail_ != tail
  }

  /// True when the producer-written and consumer-written indices are on different cache lines.
  [[nodiscard]] static constexpr bool indices_on_separate_lines() noexcept {
    return offsetof(SpscRing, tail_) / kCacheLine != offsetof(SpscRing, head_) / kCacheLine;
  }

 private:
  static constexpr std::uint64_t kMask = Capacity - 1;

  alignas(kCacheLine) std::atomic<std::uint64_t> tail_{0};  // written by the producer
  std::uint64_t cached_head_ = 0;                           // producer's last look at head_
  alignas(kCacheLine) std::atomic<std::uint64_t> head_{0};  // written by the consumer
  std::uint64_t cached_tail_ = 0;                           // consumer's last look at tail_
  alignas(kCacheLine) std::array<T, Capacity> slots_{};
};

}  // namespace lowlat::offheap
