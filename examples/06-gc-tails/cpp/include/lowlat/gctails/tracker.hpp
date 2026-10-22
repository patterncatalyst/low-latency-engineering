// The Ch6 C++ lane: the same tracker as the Java lane, with the cost of freeing memory made visible.
//
// C++ has no collector, so the work a collector does in the background is done where the program
// says: an object dies at its destructor. A shift manifest is a wave of entries that each own several
// heap blocks, so destroying the finished wave is tens of thousands of free() calls. Where those
// calls run is the policy:
//
//   bulk_free      the wave is destroyed on the hot thread, in the call that closes the wave.
//   deferred_free  the wave is moved to a reclaimer thread, which destroys it.
//   no_free        the wave is kept until the end of the run (the control: the cost of the hand-off
//                  alone, with no destruction anywhere in the measured window).
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>
#include <queue>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

namespace lowlat::gctails {

enum class Policy { bulk_free, deferred_free, no_free };

/// "bulk-free", "deferred-free" or "no-free" (the report variants).
[[nodiscard]] std::optional<Policy> parse_policy(std::string_view variant) noexcept;
[[nodiscard]] std::string_view name(Policy policy) noexcept;

struct Settings {
  std::uint64_t rate = 10'000;       ///< Parcels per second (sizes the in-flight window).
  std::size_t wave_parcels = 10'000; ///< Parcels per manifest wave; one second of the line at 10 kHz.
  std::size_t entry_bytes = 1024;    ///< Label bytes per manifest entry.
  std::size_t stages = 4;            ///< Stage strings per entry; each is its own heap block.
  int in_flight_ms = 480;            ///< Time between the scanner and the diverter.
};

/// A manifest line. Seven heap blocks: the barcode, the label, the stage vector and four stage strings.
struct Entry {
  std::string barcode;
  std::vector<std::byte> label;
  std::vector<std::string> stages;
  std::uint64_t seq = 0;
};

using Wave = std::vector<Entry>;

/// Destroys waves on its own thread. Handing a wave over is a mutex, a push and a notify; the
/// frees happen elsewhere.
class Reclaimer {
 public:
  Reclaimer() : thread_([this](const std::stop_token& stop) { run(stop); }) {}

  void submit(Wave&& wave) {
    {
      const std::lock_guard lock{mutex_};
      queue_.push(std::move(wave));
    }
    wake_.notify_one();
  }

  /// Entries destroyed so far (the reclaimer thread's count, read with relaxed order).
  [[nodiscard]] std::uint64_t reclaimed() const noexcept { return reclaimed_.load(std::memory_order_relaxed); }

  /// Stops the thread after it has destroyed everything submitted, and joins it.
  void finish();

 private:
  void run(const std::stop_token& stop);

  std::mutex mutex_;
  std::condition_variable_any wake_;
  std::queue<Wave> queue_;
  std::atomic<std::uint64_t> reclaimed_ = 0;
  std::jthread thread_;  // last: starts only after the members above exist
};

class Tracker {
 public:
  Tracker(Policy policy, const Settings& settings);

  /// Handles one parcel: lane lookup, manifest entry, in-flight table. Returns the lane. When the
  /// parcel closes a wave, the wave before it is disposed of according to the policy, inside this call.
  unsigned track(std::string_view barcode, std::uint64_t seq);

  /// Waves closed so far.
  [[nodiscard]] std::uint64_t waves_closed() const noexcept { return waves_closed_; }
  /// Entries destroyed on the calling (hot) thread by `bulk_free`.
  [[nodiscard]] std::uint64_t destroyed_inline() const noexcept { return destroyed_inline_; }
  /// Entries the reclaimer has destroyed so far (`deferred_free`).
  [[nodiscard]] std::uint64_t reclaimed() const noexcept { return reclaimer_ ? reclaimer_->reclaimed() : 0; }
  /// Entries held back by `no_free`.
  [[nodiscard]] std::uint64_t retained() const noexcept { return retained_entries_; }
  [[nodiscard]] Policy policy() const noexcept { return policy_; }

  /// Ends the run: lets the reclaimer finish. Call it after the measured window.
  void finish();

 private:
  struct State {
    std::uint64_t seq;
    unsigned lane;
  };

  Entry make_entry(std::string_view barcode, std::uint64_t seq) const;
  void close_wave();

  Policy policy_;
  Settings settings_;
  Wave current_;
  Wave previous_;
  std::deque<Wave> retained_;  // no_free keeps the dead waves here
  std::optional<Reclaimer> reclaimer_;
  std::unordered_map<std::string, State> in_flight_;
  std::deque<std::string> in_flight_order_;
  std::size_t in_flight_capacity_;
  std::uint64_t waves_closed_ = 0;
  std::uint64_t destroyed_inline_ = 0;
  std::uint64_t retained_entries_ = 0;
};

/// An SSCC-shaped 18-digit string for warm-up parcels.
[[nodiscard]] std::string synthetic_barcode(std::uint64_t n);

}  // namespace lowlat::gctails
