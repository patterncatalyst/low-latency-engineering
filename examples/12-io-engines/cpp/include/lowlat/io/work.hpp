// What every receive engine does with a datagram once it has one: decode, check the sequence,
// decide the lane, record the latency from the intended emit time. The engines differ in how a
// datagram reaches this code, never in what happens to it.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <new>
#include <optional>
#include <span>
#include <string_view>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/measure/recorder.hpp"
#include "parcel-v1/parcel_v1.hpp"

namespace lowlat::io {

namespace flat = lowlat::flat::parcel_v1;

inline constexpr std::size_t kCameras = 4;

/// Exact in-program counters of one thread. Each thread owns one and writes only to it; the array
/// that holds them is padded so two threads never share a line. 2 x the destructive-interference
/// size because the L2 spatial prefetcher on recent Intel cores pulls adjacent line pairs.
struct alignas(2 * std::hardware_destructive_interference_size) EngineCounters {
  std::uint64_t datagrams = 0;   ///< datagrams that reached user space
  std::uint64_t malformed = 0;   ///< datagrams that were not an 80-byte parcel-v1 record
  std::uint64_t parcels = 0;     ///< parcels decided (lane looked up and latency recorded)
  std::uint64_t epoll_waits = 0;
  std::uint64_t recvmsgs = 0;    ///< recvmsg calls, EAGAIN included
  std::uint64_t recvmmsgs = 0;   ///< recvmmsg calls, EAGAIN included
  std::uint64_t enters = 0;      ///< io_uring_enter calls (submit_and_wait)
  std::uint64_t cqes = 0;        ///< completions reaped
  std::uint64_t rearms = 0;      ///< multishot receives re-submitted after the kernel ended them
  std::uint64_t handoffs = 0;    ///< parcels passed to a different thread
  std::int64_t start_ns = 0;     ///< CLOCK_MONOTONIC at the first instruction after the start gate
  std::array<std::uint64_t, line::kLanes> lanes{};  ///< the decide step's result, kept so it cannot be elided

  /// Every system call the receive path made: the number the strace cross-check compares against.
  [[nodiscard]] std::uint64_t syscalls() const noexcept { return epoll_waits + recvmsgs + recvmmsgs + enters; }

  EngineCounters& operator+=(const EngineCounters& o) noexcept {
    datagrams += o.datagrams;
    malformed += o.malformed;
    parcels += o.parcels;
    epoll_waits += o.epoll_waits;
    recvmsgs += o.recvmsgs;
    recvmmsgs += o.recvmmsgs;
    enters += o.enters;
    cqes += o.cqes;
    rearms += o.rearms;
    handoffs += o.handoffs;
    for (std::size_t i = 0; i < lanes.size(); ++i) lanes[i] += o.lanes[i];
    return *this;
  }
};
static_assert(alignof(EngineCounters) >= 2 * std::hardware_destructive_interference_size);
static_assert(sizeof(EngineCounters) % alignof(EngineCounters) == 0);

/// The last step of the start: each thread arrives and spins until every thread has, then reads the
/// clock. The kernel's wake-up from the gate's futex barrier can take a millisecond on a core that
/// was idle; spinning here brings the threads to the same instant, and the skew that is recorded
/// is the spread of the clock reads after it.
class SpinStart {
 public:
  explicit SpinStart(int threads) noexcept : threads_(threads) {}
  /// The CLOCK_MONOTONIC time at which this thread left the gate.
  [[nodiscard]] std::int64_t arrive_and_go() noexcept {
    arrived_.fetch_add(1, std::memory_order_acq_rel);
    while (arrived_.load(std::memory_order_acquire) < threads_) {
    }
    return line::monotonic_ns();
  }

 private:
  alignas(2 * std::hardware_destructive_interference_size) std::atomic<int> arrived_{0};
  int threads_;
};

/// One camera's socket and its sequence accounting. Parcels are numbered from 0 without gaps.
struct Camera {
  int fd = -1;
  std::uint64_t expect = 0;
  line::SeqTracker tracker;

  [[nodiscard]] bool complete() const noexcept { return tracker.received() + tracker.dropped() >= expect; }
  /// Parcels that never arrived: every one the camera was due to send and this side did not see.
  [[nodiscard]] std::uint64_t lost() const noexcept { return expect > tracker.received() ? expect - tracker.received() : 0; }
};

[[nodiscard]] inline bool all_complete(std::span<const Camera> cameras) noexcept {
  for (const Camera& c : cameras) {
    if (!c.complete()) return false;
  }
  return true;
}

/// Decode and sequence-check one datagram. The parcel when it is new, nothing for a malformed or
/// repeated one.
[[nodiscard]] inline std::optional<flat::Parcel> accept(Camera& camera, std::span<const std::byte> bytes,
                                                        EngineCounters& counters) {
  ++counters.datagrams;
  const auto decoded = flat::decode(bytes);
  if (!decoded) {
    ++counters.malformed;
    return std::nullopt;
  }
  if (camera.tracker.observe(decoded->seq) == line::SeqTracker::Kind::reordered) return std::nullopt;
  return *decoded;
}

/// Busy-waits for `ns` nanoseconds of CLOCK_MONOTONIC. It stands in for the part of the real decide
/// that this example does not build (the tracker lookup and the divert command's encode), so that a
/// single receive thread has a capacity the simulators can exceed. The clock reads keep the loop
/// from being removed.
inline void spin_work(std::int64_t ns) noexcept {
  if (ns <= 0) return;
  const std::int64_t until = line::monotonic_ns() + ns;
  while (line::monotonic_ns() < until) {
  }
}

/// The decide step: look up the lane for the barcode, spend `work_ns` of modelled decide work, and
/// record the latency from the intended emit time. The lane counts live in the thread's counters,
/// so the lookup has an observable effect and the optimiser cannot remove it.
inline void decide(std::string_view barcode, std::uint64_t seq, std::int64_t intended_emit_ns, EngineCounters& counters,
                   measure::Recorder& latency, std::int64_t work_ns = 0) {
  ++counters.lanes[line::lane_for(barcode)];
  spin_work(work_ns);
  ++counters.parcels;
  const std::int64_t latency_ns = line::monotonic_ns() - intended_emit_ns;
  if (latency_ns < 0) [[unlikely]] line::throw_negative_latency(latency_ns, seq);
  latency.record(latency_ns);
}

inline void decide(const flat::Parcel& p, EngineCounters& counters, measure::Recorder& latency, std::int64_t work_ns = 0) {
  decide(flat::barcode_view(p), p.seq, p.intended_emit_ns, counters, latency, work_ns);
}

}  // namespace lowlat::io
