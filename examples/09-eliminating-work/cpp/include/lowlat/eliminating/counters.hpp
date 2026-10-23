// Per-camera counters: five scan-tunnel cameras, one writer thread each, bumping their own read and
// no-read counts while a telemetry thread samples all of them.
//
// Each counter has exactly one writer, so an increment is a relaxed load plus a relaxed store: no
// read-modify-write and no lock prefix. What is left to cost is where the counters sit. Neighbouring
// cameras on one cache line make every store invalidate the other cameras' copies of that line
// (false sharing), although no two threads ever touch the same counter.
//
// The padding below is not idiomatic C++ in general: it is a measured latency construct, used here
// because the layout is the technique. std::hardware_destructive_interference_size is the standard's
// name for "keep two writers this far apart"; GCC's -Winterference-size is switched off project-wide
// because no layout crosses a build.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <new>

namespace lowlat::eliminating {

inline constexpr std::size_t kCameras = 5;
inline constexpr std::size_t kLine = std::hardware_destructive_interference_size;  // 64 B on x86-64
inline constexpr std::size_t kLinePair = 2 * kLine;  // 128 B: the L2 spatial prefetcher fetches line pairs

/// One camera's counters, aligned to `Align` bytes (the size of the struct rounds up to it too).
template <std::size_t Align>
struct alignas(Align) CameraCounters {
  std::atomic<std::uint64_t> reads{0};
  std::atomic<std::uint64_t> no_reads{0};

  // Single writer: load and store, never fetch_add.
  void bump_read() noexcept { reads.store(reads.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed); }
  void bump_no_read() noexcept {
    no_reads.store(no_reads.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
  }
  // The same count as an atomic read-modify-write (lock xadd on x86): what a counter that may gain a second
  // writer looks like. Used for the contrast run only.
  void add_read() noexcept { reads.fetch_add(1, std::memory_order_relaxed); }
  void add_no_read() noexcept { no_reads.fetch_add(1, std::memory_order_relaxed); }
  [[nodiscard]] std::uint64_t total() const noexcept {
    return reads.load(std::memory_order_relaxed) + no_reads.load(std::memory_order_relaxed);
  }
};

using AdjacentCamera = CameraCounters<alignof(std::uint64_t)>;  // 16 B each: four cameras per line
using LinePaddedCamera = CameraCounters<kLine>;                 // 64 B each: one camera per line
using PairPaddedCamera = CameraCounters<kLinePair>;             // 128 B each: one camera per line pair

static_assert(sizeof(AdjacentCamera) == 16);
static_assert(sizeof(LinePaddedCamera) == kLine);
static_assert(sizeof(PairPaddedCamera) == kLinePair);

template <class Camera>
using CounterBank = std::array<Camera, kCameras>;

/// A bank on the heap, over-aligned storage included (aligned operator new, C++17).
template <class Camera>
[[nodiscard]] std::unique_ptr<CounterBank<Camera>> make_bank() {
  return std::make_unique<CounterBank<Camera>>();
}

/// Cache lines (of `line` bytes) that the first byte of cameras `a` and `b` fall in: equal means the two
/// cameras' counters share a line. Used by the layout tests.
template <class Camera>
[[nodiscard]] bool share_line(const CounterBank<Camera>& bank, std::size_t a, std::size_t b, std::size_t line) noexcept {
  const auto addr = [&](std::size_t i) { return reinterpret_cast<std::uintptr_t>(&bank[i]); };
  return addr(a) / line == addr(b) / line;
}

}  // namespace lowlat::eliminating
