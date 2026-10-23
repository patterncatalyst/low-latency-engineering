// The Ch7 hand-off: the receive thread decodes each datagram and hands a small record to a decide
// thread through a single-producer single-consumer ring. Two ways for the decide thread to wait
// for the next record:
//
//   spin   spin on the producer's index (an acquire load) until it moves.
//   park   std::atomic::wait on the index; the producer calls notify_one after every push.
//
// The hand-off latency is the time from the receive thread's stamp, taken just before the push,
// to the decide thread's first look at the record. The end-to-end latency is the line's usual
// intended-emit-to-done, with the Completion owned by the decide thread.
#pragma once

#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <format>
#include <optional>
#include <print>
#include <string>
#include <string_view>
#include <thread>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/offheap/spsc_ring.hpp"

namespace lowlat::offheap {

inline constexpr std::size_t kHandoffSlots = std::size_t{1} << 16;

// A record with this seq tells the decide thread to end. It travels through the ring because a
// consumer parked in atomic::wait cannot be woken by a stop request.
inline constexpr std::uint64_t kStop = ~std::uint64_t{0};

struct Scan {
  std::uint64_t seq = 0;
  std::int64_t intended_ns = 0;
  std::int64_t rx_ns = 0;  // CLOCK_MONOTONIC on the receive thread, just before the push
};

enum class Wait { spin, park };

/// The CPU's spin-wait hint where there is one: it tells the core this is a polling loop.
inline void cpu_relax() noexcept {
#if defined(__x86_64__) || defined(__i386__)
  __builtin_ia32_pause();
#elif defined(__aarch64__)
  asm volatile("yield");
#endif
}

/// The ParcelHandler: receive-thread side of the hand-off, and the owner of the decide thread.
class Handoff {
 public:
  Handoff(Wait wait, std::string_view example, std::string_view variant, std::uint64_t window,
          std::chrono::milliseconds hold)
      : wait_(wait),
        hold_(hold),
        handoff_(std::string{example}, std::format("{}-handoff", variant)),
        handoff_windows_(std::string{example}, std::format("{}-handoff", variant), window),
        decide_([this] { decide(); }) {}

  Handoff(const Handoff&) = delete;
  Handoff& operator=(const Handoff&) = delete;
  ~Handoff() { stop_decide(); }

  /// Receive thread.
  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    // The decide thread reads `dx_.done` only after it has popped a record, and the first record is
    // pushed after this store: the ring's release/acquire pair orders it. Written once, never again.
    if (dx_.done == nullptr) dx_.done = &done;
    const Scan scan{.seq = ev.seq(), .intended_ns = ev.intended_emit_ns(), .rx_ns = line::monotonic_ns()};
    if (ring_.try_push(scan)) {
      ++rx_.published;
      if (wait_ == Wait::park) ring_.notify_consumer();
    } else {
      ++rx_.overflow;  // full: the belt does not wait, the count shows the loss
    }
  }

  /// Waits for the decide thread to handle everything, prints the sampling marker, holds, joins.
  /// Rethrows what ended the decide thread early (a negative latency, a recorder failure).
  void drain(line::Completion&) {
    while (!dx_.failed.load(std::memory_order_acquire) && dx_.handled.load(std::memory_order_acquire) < rx_.published) {
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
    if (!dx_.failed.load(std::memory_order_acquire)) {
      std::println("window-end handled={}", dx_.handled.load(std::memory_order_acquire));
      std::fflush(stdout);
      std::this_thread::sleep_for(hold_);
    }
    stop_decide();
    if (dx_.error) std::rethrow_exception(dx_.error);  // read after the join: ordered by it
  }

  [[nodiscard]] std::uint64_t published() const noexcept { return rx_.published; }
  [[nodiscard]] std::uint64_t overflow() const noexcept { return rx_.overflow; }
  /// True when the receive-written and decide-written members are in different false-sharing
  /// ranges. Each group is a type aligned to the range, so its size is a multiple of the range and
  /// two groups can never share one (checked by a static_assert below and by the tests).
  [[nodiscard]] static constexpr bool writers_on_separate_lines() noexcept {
    return alignof(ReceiveSide) >= kFalseSharingRange && alignof(DecideSide) >= kFalseSharingRange &&
           sizeof(ReceiveSide) % kFalseSharingRange == 0 && sizeof(DecideSide) % kFalseSharingRange == 0;
  }
  [[nodiscard]] measure::Recorder& handoff() noexcept { return handoff_; }
  [[nodiscard]] line::WindowedRecorders& handoff_windows() noexcept { return handoff_windows_; }

 private:
  void decide() {
    // One parseable line: a script reads /proc/PID/task/TID/status (context switches) from it.
    std::println("decide-thread pid={} tid={}", ::getpid(), ::gettid());
    std::fflush(stdout);
    try {
      std::uint64_t handled = 0;
      while (true) {
        std::optional<Scan> scan = ring_.try_pop();
        while (!scan) {
          if (wait_ == Wait::spin) cpu_relax(); else ring_.wait_for_data();
          scan = ring_.try_pop();
        }
        const std::int64_t pickup_ns = line::monotonic_ns();
        if (scan->seq == kStop) return;
        const std::int64_t handoff_ns = pickup_ns - scan->rx_ns;
        handoff_.record(handoff_ns);
        handoff_windows_.record(scan->seq, handoff_ns);
        dx_.done->complete(scan->seq, scan->intended_ns, line::monotonic_ns());
        dx_.handled.store(++handled, std::memory_order_release);
      }
    } catch (...) {
      dx_.error = std::current_exception();
      dx_.failed.store(true, std::memory_order_release);
    }
  }

  void stop_decide() {
    if (!decide_.joinable()) return;
    // A decide thread that has died never frees a slot, so a full ring must not hold the stop back.
    while (!ring_.try_push(Scan{.seq = kStop}) && !dx_.failed.load(std::memory_order_acquire)) std::this_thread::yield();
    if (wait_ == Wait::park) ring_.notify_consumer();
    decide_.join();
  }

  // Members grouped by writer, each group in its own false-sharing range. The receive thread
  // writes `rx_.published` on every push; the decide thread release-stores `dx_.handled` on every
  // record. Sharing a line, the two would trade it back and forth once per record, on the hot path.
  struct alignas(kFalseSharingRange) ReceiveSide {
    std::uint64_t published = 0;  // receive thread only
    std::uint64_t overflow = 0;   // receive thread only
  };
  struct alignas(kFalseSharingRange) DecideSide {
    // Written once by the receive thread before the first push and only read here afterwards, so
    // it costs one transfer, not one per record.
    line::Completion* done = nullptr;
    std::atomic<std::uint64_t> handled = 0;
    std::atomic<bool> failed = false;  // set by the decide thread, after error is written
    std::exception_ptr error;          // decide thread writes it before failed; read after the join
  };

  Wait wait_;
  std::chrono::milliseconds hold_;
  SpscRing<Scan, kHandoffSlots> ring_;
  measure::Recorder handoff_;
  line::WindowedRecorders handoff_windows_;
  ReceiveSide rx_;
  DecideSide dx_;
  std::jthread decide_;  // last member: starts after everything it uses exists
};
static_assert(Handoff::writers_on_separate_lines());

}  // namespace lowlat::offheap
