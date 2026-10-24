// The acceptor-plus-pool layout: one receive thread passes each parcel to one of N worker threads
// through Ch10's multi-producer log (lowlat::lockfree::ClaimLog, wait-free fetch_add claim). With a
// single producer per log the claim is uncontended; the cost shown here is the hand-off itself: the
// cache lines that move between cores and the worker's wake-up from its spin.
// Depends on examples/10-lockfree-waitfree (the lowlat::lockfree library).
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string_view>
#include <type_traits>
#include <vector>

#include "lowlat/io/work.hpp"
#include "lowlat/lockfree/claim.hpp"
#include "lowlat/lockfree/claim_log.hpp"

namespace lowlat::io {

/// A parcel on its way from the receive thread to a worker.
struct Handoff {
  std::uint64_t seq = 0;
  std::int64_t intended_emit_ns = 0;
  std::array<char, 24> barcode{};
};
static_assert(std::is_trivially_copyable_v<Handoff>);

inline constexpr std::uint64_t kEndOfRun = ~std::uint64_t{0};

class HandoffPool {
 public:
  explicit HandoffPool(std::size_t workers, std::size_t capacity = 1U << 14) : stats_(workers) {
    logs_.reserve(workers);
    for (std::size_t i = 0; i < workers; ++i) logs_.push_back(std::make_unique<Log>(capacity));
  }

  [[nodiscard]] std::size_t workers() const noexcept { return logs_.size(); }

  /// Receive thread only: hand the parcel to the next worker in turn. Counts one hand-off.
  void send(const flat::Parcel& p, EngineCounters& counters) {
    Handoff h;
    h.seq = p.seq;
    h.intended_emit_ns = p.intended_emit_ns;
    std::memcpy(h.barcode.data(), p.barcode.data(), p.barcode.size());
    publish(next_++ % logs_.size(), h);
    ++counters.handoffs;
  }

  /// Receive thread only, at the end of the run: tell every worker to stop.
  void finish() {
    Handoff end;
    end.seq = kEndOfRun;
    for (std::size_t w = 0; w < logs_.size(); ++w) publish(w, end);
  }

  /// Worker `w`: decide parcels in the order they were handed over until the end marker.
  void work(std::size_t w, EngineCounters& counters, measure::Recorder& latency, std::int64_t work_ns = 0) {
    Log& log = *logs_[w];
    for (std::uint64_t slot = 0;; ++slot) {
      std::int64_t waited_ns = 0;
      const Handoff h = log.read(slot, waited_ns);
      log.consumed(slot);
      if (h.seq == kEndOfRun) return;
      decide(std::string_view{h.barcode.data(), flat::kBarcodeLen}, h.seq, h.intended_emit_ns, counters, latency, work_ns);
    }
  }

 private:
  using Log = lockfree::ClaimLog<lockfree::FetchAddClaim, Handoff>;

  void publish(std::size_t w, const Handoff& h) {
    lockfree::ClaimStats& stats = stats_[w];
    logs_[w]->publish(logs_[w]->claim(stats), h, stats);
  }

  std::vector<std::unique_ptr<Log>> logs_;
  std::vector<lockfree::ClaimStats> stats_;  // one per log, written only by the receive thread
  std::size_t next_ = 0;
};

}  // namespace lowlat::io
