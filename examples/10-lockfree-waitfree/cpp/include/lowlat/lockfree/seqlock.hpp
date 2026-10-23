// Parcel-state snapshots for readers that must never delay the writer.
//
// The tracker updates a parcel's state at 1 MHz; the diverter and the HMI read it. Two ways to
// share it:
//   SharedMutexCell  std::shared_mutex: readers share, the writer excludes them. A steady stream of
//                    readers keeps the writer waiting for the lock.
//   Seqlock          the writer never waits for a reader. A reader copies the fields and keeps the
//                    copy only if the sequence number was even and did not change meanwhile.
//
// A seqlock written with plain fields is a data race in C++: the reader copies fields while the
// writer stores them, and a data race is undefined behaviour even when the reader discards the
// copy. The fields here are std::atomic_ref<uint64_t> accessed with relaxed order, which is
// race-free by definition and compiles to ordinary mov instructions on x86-64; the ordering comes
// from the sequence number (release store, acquire load) and a pair of fences.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <shared_mutex>
#include <type_traits>

namespace lowlat::lockfree {

/// What the tracker knows about one parcel: eight 64-bit words, the last a checksum of the others.
/// A reader that gets words from two different updates sees a checksum that does not match.
struct ParcelSnapshot {
  static constexpr std::size_t kWords = 8;
  std::array<std::uint64_t, kWords> word{};

  /// The snapshot written by update number `n`: every word is a function of `n`.
  [[nodiscard]] static ParcelSnapshot of(std::uint64_t n) noexcept {
    ParcelSnapshot s;
    for (std::size_t i = 0; i + 1 < kWords; ++i) s.word[i] = n * (2 * i + 3) + i;
    s.word[kWords - 1] = checksum(s);
    return s;
  }
  [[nodiscard]] static std::uint64_t checksum(const ParcelSnapshot& s) noexcept {
    std::uint64_t sum = 0x9e3779b97f4a7c15ULL;
    for (std::size_t i = 0; i + 1 < kWords; ++i) sum = (sum ^ s.word[i]) * 0x100000001b3ULL;
    return sum;
  }
  [[nodiscard]] bool consistent() const noexcept { return word[kWords - 1] == checksum(*this); }
};
static_assert(std::is_trivially_copyable_v<ParcelSnapshot>);

class SharedMutexCell {
 public:
  void write(const ParcelSnapshot& s) {
    const std::unique_lock lock{mutex_};
    value_ = s;
  }
  [[nodiscard]] ParcelSnapshot read() const {
    const std::shared_lock lock{mutex_};
    return value_;
  }

 private:
  mutable std::shared_mutex mutex_;
  ParcelSnapshot value_ = ParcelSnapshot::of(0);  // guarded by mutex_
};

class Seqlock {
 public:
  Seqlock() noexcept { write(ParcelSnapshot::of(0)); }

  /// One writer only.
  void write(const ParcelSnapshot& s) noexcept {
    const std::uint64_t seq = sequence_.load(std::memory_order_relaxed);
    sequence_.store(seq + 1, std::memory_order_relaxed);  // odd: a write is in progress
    std::atomic_thread_fence(std::memory_order_release);  // the odd value is visible before any field store
    for (std::size_t i = 0; i < ParcelSnapshot::kWords; ++i) {
      std::atomic_ref<std::uint64_t>{words_[i]}.store(s.word[i], std::memory_order_relaxed);
    }
    sequence_.store(seq + 2, std::memory_order_release);  // even: the fields are visible before this
  }

  /// One attempt: true and `out` filled when the copy is consistent, false when a write overlapped.
  [[nodiscard]] bool try_read(ParcelSnapshot& out) const noexcept {
    const std::uint64_t before = sequence_.load(std::memory_order_acquire);
    if (before & 1U) return false;
    for (std::size_t i = 0; i < ParcelSnapshot::kWords; ++i) {
      out.word[i] = std::atomic_ref<std::uint64_t>{words_[i]}.load(std::memory_order_relaxed);
    }
    std::atomic_thread_fence(std::memory_order_acquire);  // the field loads happen before the re-check
    return sequence_.load(std::memory_order_relaxed) == before;
  }

  /// Retries until an attempt succeeds; `retries` counts the failed attempts.
  [[nodiscard]] ParcelSnapshot read(std::uint64_t& retries) const noexcept {
    ParcelSnapshot s;
    while (!try_read(s)) ++retries;
    return s;
  }

 private:
  std::atomic<std::uint64_t> sequence_{0};
  // atomic_ref needs the object to outlive it and to be aligned to atomic_ref's requirement.
  alignas(std::atomic_ref<std::uint64_t>::required_alignment) mutable std::array<std::uint64_t, ParcelSnapshot::kWords> words_{};
};

}  // namespace lowlat::lockfree
