// The C++ line consumer: UDP receive, ParcelEvent decode, per-parcel work,
// latency against the intended emit time. See ../../../../README.md.
#pragma once

#include <sys/socket.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <concepts>
#include <cstdint>
#include <filesystem>
#include <format>
#include <functional>
#include <new>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/fd.hpp"
#include "lowlat/line/v1/parcel.pb.h"
#include <nlohmann/json.hpp>

#include "lowlat/measure/recorder.hpp"

namespace lowlat::line {

struct ConsumerConfig {
  std::string bind = "127.0.0.1:47000";   ///< host:port (IPv4).
  int rcvbuf = 4 * 1024 * 1024;           ///< SO_RCVBUF request, bytes.
  std::optional<std::uint64_t> expect;    ///< Stop after received + dropped reaches this.
  int idle_timeout_ms = 2000;             ///< Stop this long after the last datagram.
  std::optional<std::filesystem::path> report;
  std::optional<std::uint64_t> window;    ///< Also report parcels seq < N and the rest apart (see WindowedRecorders).
  std::string example = "00-line-consumer";
  std::string variant = "baseline";
};

/// Throws std::invalid_argument on an unknown option, missing value or bad value.
[[nodiscard]] ConsumerConfig parse_consumer_args(std::span<const std::string_view> args);
[[nodiscard]] std::string_view consumer_usage() noexcept;

/// Sequence accounting. Parcels are numbered from 0 without gaps, so the next
/// expected number is the highest seen plus one (0 before anything arrives).
/// A jump forward adds the skipped count to `dropped`; a number at or below
/// the highest seen is `reordered` (or duplicated) and is not counted again.
///
/// With a `window`, it also counts how many of the dropped parcels had a
/// number below it, so a windowed report can book each drop in the window it
/// belongs to.
class SeqTracker {
 public:
  enum class Kind { in_order, gap, reordered };

  explicit SeqTracker(std::uint64_t window = 0) noexcept : window_(window) {}

  Kind observe(std::uint64_t seq) noexcept;

  [[nodiscard]] std::uint64_t received() const noexcept { return received_; }  ///< In order or after a gap.
  [[nodiscard]] std::uint64_t dropped() const noexcept { return dropped_; }
  [[nodiscard]] std::uint64_t reordered() const noexcept { return reordered_; }
  [[nodiscard]] std::uint64_t dropped_below_window() const noexcept { return dropped_below_window_; }

 private:
  std::uint64_t window_;
  std::uint64_t dropped_below_window_ = 0;
  std::uint64_t next_ = 0;
  std::uint64_t received_ = 0;
  std::uint64_t dropped_ = 0;
  std::uint64_t reordered_ = 0;
};

inline constexpr unsigned kLanes = 8;

/// The per-parcel work: decode the SSCC-18 serial reference (digits 9..17 of the
/// 18-digit code: extension, 7-digit prefix, 9-digit serial, check digit) and
/// map it to a lane, serial modulo 8. Throws std::invalid_argument for a
/// barcode that is not 18 ASCII digits.
[[nodiscard]] unsigned lane_for(std::string_view sscc);

struct ConsumerResult {
  std::uint64_t received = 0;
  std::uint64_t dropped = 0;
  std::uint64_t reordered = 0;
  std::uint64_t malformed = 0;
  int granted_rcvbuf = 0;  ///< What getsockopt(SO_RCVBUF) reports (Linux doubles the request).
  std::string stopped_by;  ///< "expect", "idle", "signal".
  std::array<std::uint64_t, kLanes> lane_counts{};  ///< Filled by consume(); a custom handler keeps its own counts.
  std::uint64_t completed = 0;          ///< Parcels a handler completed (and so recorded).
  std::int64_t first_done_ns = 0;       ///< done_ns of the first completion (0 when none).
  std::int64_t last_done_ns = 0;        ///< done_ns of the latest completion.
};

/// Called once the socket is bound and sized, before the first receive:
/// `granted_rcvbuf` is what getsockopt(SO_RCVBUF) reports (Linux doubles the
/// request and caps it at net.core.rmem_max); `port` is the bound port.
using ReadyFn = std::function<void(int port, int granted_rcvbuf)>;

/// Longest the receive blocks before the loop re-checks the stop flag.
inline constexpr int kTickMs = 100;

/// A bound socket and the SO_RCVBUF the kernel granted for it.
struct Bound {
  Fd fd;
  int rcvbuf_granted;
};

/// A bound IPv4 UDP socket with SO_RCVBUF requested (`rcvbuf_granted` is what the
/// kernel gave) and a receive timeout of `tick_ms`. Throws on any socket error.
[[nodiscard]] Bound open_bound(const std::string& bind_to, int rcvbuf, int tick_ms);
[[nodiscard]] int bound_port_of(int fd);

[[noreturn]] void throw_negative_latency(std::int64_t latency_ns, std::uint64_t seq);

/// Latency of the same run split at parcel `window`: parcels with seq below it
/// go to `first()`, the rest to `steady()`. The first window carries the
/// warm-up (JIT, page faults, cold caches), the steady one what follows; the
/// two counts add up to the full report's count.
///
/// Recorded in addition to the full recorder, not instead of it, so the full
/// `<variant>` report keeps meaning what it always meant. Only a run given a
/// window pays the second record.
class WindowedRecorders {
 public:
  WindowedRecorders(const std::string& example, const std::string& variant, std::uint64_t window)
      : window_(window),
        first_(example, std::format("{}-first-{}", variant, window)),
        steady_(example, std::format("{}-steady", variant)) {}

  [[nodiscard]] std::uint64_t window() const noexcept { return window_; }
  [[nodiscard]] measure::Recorder& first() noexcept { return first_; }
  [[nodiscard]] measure::Recorder& steady() noexcept { return steady_; }

  void record(std::uint64_t seq, std::int64_t latency_ns) { (seq < window_ ? first_ : steady_).record(latency_ns); }

  /// Writes `<stem>-first-N<ext>` and `<stem>-steady<ext>` beside `report` and
  /// returns the two paths. Call it from the thread that owns the Completion's
  /// data after that thread has finished (see Completion).
  std::vector<std::filesystem::path> write_reports(const std::filesystem::path& report, std::string_view notes = {},
                                                   const std::optional<nlohmann::json>& runtime = std::nullopt) const;

 private:
  std::uint64_t window_;
  measure::Recorder first_;
  measure::Recorder steady_;
};

/// Where a handler reports that a parcel is done. The loop records
/// `done_ns - intended_emit_ns` at that moment, so a handler may complete a
/// parcel inside the call (per-parcel) or later (a batch holds parcels, keeps
/// `ev.intended_emit_ns()` and completes them all when the batch is full). It
/// also keeps first/last done time for throughput.
///
/// Ownership. Completion is single-writer: at any moment exactly one thread
/// calls `complete`. That thread is the receive thread unless the handler moves
/// ownership, for example to a decide thread (Ch7): the handler keeps the
/// `Completion&` it was given, starts a `std::jthread` that calls `complete`,
/// and in `drain` stops and joins it. The loop reads `count()` and the done
/// times only after `drain` returns, so the join is the happens-before edge that
/// publishes the recorder's contents; no lock or atomic is needed on the
/// recording path. Once the handler has handed over, the receive thread must not
/// call `complete`, and the owner must use the overloads that take `seq` (the
/// loop's `begin` sets the seq the two-argument form uses for its error message
/// and its window).
///
/// False sharing. The receive thread writes `seq_` for every parcel and the owner
/// writes `count_` and the done times for every parcel, so the two groups sit in
/// separate 128-byte ranges: without that, a hand-off to a decide thread would add a
/// line ping-pong to the path Ch7 measures.
class Completion {
 public:
  explicit Completion(measure::Recorder& latency, WindowedRecorders* windows = nullptr) noexcept
      : latency_(&latency), windows_(windows) {}

  /// Done now: the clock is read here.
  void complete(const v1::ParcelEvent& ev) { complete(ev.seq(), ev.intended_emit_ns(), monotonic_ns()); }

  /// Done at `done_ns` (one clock read can serve a whole batch), for the parcel
  /// the loop is handling now. A batch that completes parcels later must use the
  /// overload with `seq` to keep a windowed run correct. Throws
  /// std::runtime_error if the latency is negative: the producer and consumer
  /// are not on one CLOCK_MONOTONIC.
  void complete(std::int64_t intended_emit_ns, std::int64_t done_ns) {
    complete(seq_.load(std::memory_order_relaxed), intended_emit_ns, done_ns);
  }

  /// As above for parcel `seq`, which decides its window.
  void complete(std::uint64_t seq, std::int64_t intended_emit_ns, std::int64_t done_ns) {
    const std::int64_t latency_ns = done_ns - intended_emit_ns;
    if (latency_ns < 0) [[unlikely]] throw_negative_latency(latency_ns, seq);
    latency_->record(latency_ns);
    if (windows_ != nullptr) windows_->record(seq, latency_ns);
    if (count_++ == 0) first_done_ns_ = done_ns;
    last_done_ns_ = done_ns;
  }

  [[nodiscard]] std::uint64_t count() const noexcept { return count_; }
  [[nodiscard]] std::int64_t first_done_ns() const noexcept { return first_done_ns_; }
  [[nodiscard]] std::int64_t last_done_ns() const noexcept { return last_done_ns_; }

  /// Loop only: the seq being handled. Relaxed atomic, so an owner thread reading it
  /// races with nothing; on x86-64 it is a plain store.
  void begin(std::uint64_t seq) noexcept { seq_.store(seq, std::memory_order_relaxed); }

 private:
  // Two destructive-interference sizes (128 bytes on x86-64): the L2 spatial prefetcher on recent
  // Intel cores fetches the adjacent line of a 128-byte pair, so writers 64 bytes apart still
  // contend. GCC's -Winterference-size is switched off project-wide (no ABI crosses a build).
  static constexpr std::size_t kFalseSharingRange = 2 * std::hardware_destructive_interference_size;

  measure::Recorder* latency_;   // read-only after construction
  WindowedRecorders* windows_;   // read-only after construction
  alignas(kFalseSharingRange) std::atomic<std::uint64_t> seq_ = 0;  // written by the receive thread
  alignas(kFalseSharingRange) std::uint64_t count_ = 0;             // written by the owner thread
  std::int64_t first_done_ns_ = 0;
  std::int64_t last_done_ns_ = 0;

 public:
  /// True when the receive-written `seq_` and the owner-written fields are in different
  /// false-sharing ranges (checked by a static_assert below and by the tests).
  [[nodiscard]] static constexpr bool writers_on_separate_lines() noexcept {
    return offsetof(Completion, count_) / kFalseSharingRange != offsetof(Completion, seq_) / kFalseSharingRange &&
           offsetof(Completion, last_done_ns_) / kFalseSharingRange != offsetof(Completion, seq_) / kFalseSharingRange;
  }
};
static_assert(Completion::writers_on_separate_lines());

/// The per-parcel hook: `handler(const v1::ParcelEvent&, Completion&)`, called
/// once per new (in-order or after a gap) parcel, after the loop has parsed and
/// sequence-checked it. The handler must call `done.complete(...)` for every
/// parcel, now or later. If it also has `drain(Completion&)` the loop calls it
/// once when the run ends, to complete what it still holds.
template <class H>
concept ParcelHandler = requires(H& h, const v1::ParcelEvent& ev, Completion& done) { h(ev, done); };

/// Binds, receives until a stop condition, calls `handler` for each new parcel
/// and books gaps into `latency` (add_dropped). Throws on socket errors or, for
/// a clock bug, when a latency is negative. `stop` may be set from a signal
/// handler.
///
/// The handler is a template parameter, not a std::function or a virtual
/// interface: the call is resolved at compile time and inlined into the loop,
/// so the hook adds no indirect call and no allocation to the measured path
/// (the same reason std::sort takes its comparator as a template argument).
/// Each example instantiates the loop once, with its own handler type.
///
/// With `windows`, every completion is also recorded into the window it belongs
/// to, and the gaps are booked into the window of the parcels that are missing.
template <ParcelHandler Handler>
ConsumerResult consume_with(const ConsumerConfig& cfg, const std::atomic<bool>& stop, measure::Recorder& latency,
                            Handler& handler, const ReadyFn& on_ready = {}, WindowedRecorders* windows = nullptr) {
  ConsumerResult result;
  const int tick_ms = std::min(kTickMs, cfg.idle_timeout_ms);
  const auto [sock, granted] = open_bound(cfg.bind, cfg.rcvbuf, tick_ms);
  result.granted_rcvbuf = granted;
  if (on_ready) on_ready(bound_port_of(sock.get()), result.granted_rcvbuf);

  SeqTracker tracker{windows != nullptr ? windows->window() : 0};
  Completion done{latency, windows};
  v1::ParcelEvent ev;
  std::array<char, 2048> datagram{};
  std::int64_t last_rx_ns = 0;
  bool started = false;

  while (true) {
    if (stop.load(std::memory_order_relaxed)) {
      result.stopped_by = "signal";
      break;
    }
    if (cfg.expect && tracker.received() + tracker.dropped() >= *cfg.expect) {
      result.stopped_by = "expect";
      break;
    }

    const ssize_t n = ::recv(sock.get(), datagram.data(), datagram.size(), 0);
    if (n < 0) {
      if (errno == EINTR) continue;  // loop head sees the stop flag
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        const std::int64_t waited_ns = monotonic_ns() - last_rx_ns;
        if (started && waited_ns >= std::int64_t{cfg.idle_timeout_ms} * 1'000'000) {
          result.stopped_by = "idle";
          break;
        }
        continue;
      }
      throw std::system_error(errno, std::generic_category(), "recv");
    }
    // Every datagram, skipped or not, counts as activity for the idle timeout.
    // Stamped here, not at completion: a handler may hold parcels for a while.
    started = true;
    last_rx_ns = monotonic_ns();

    if (!ev.ParseFromArray(datagram.data(), static_cast<int>(n))) {
      ++result.malformed;
      continue;
    }
    if (tracker.observe(ev.seq()) == SeqTracker::Kind::reordered) continue;

    done.begin(ev.seq());
    handler(static_cast<const v1::ParcelEvent&>(ev), done);
  }
  if constexpr (requires { handler.drain(done); }) handler.drain(done);

  latency.add_dropped(tracker.dropped());
  if (windows != nullptr) {
    windows->first().add_dropped(tracker.dropped_below_window());
    windows->steady().add_dropped(tracker.dropped() - tracker.dropped_below_window());
  }
  result.received = tracker.received();
  result.dropped = tracker.dropped();
  result.reordered = tracker.reordered();
  result.completed = done.count();
  result.first_done_ns = done.first_done_ns();
  result.last_done_ns = done.last_done_ns();
  return result;
}

/// The example 00 consumer: `consume_with` and a handler that looks up the lane
/// (the per-parcel work) and completes the parcel at once. Fills `lane_counts`.
ConsumerResult consume(const ConsumerConfig& cfg, const std::atomic<bool>& stop, measure::Recorder& latency,
                       const ReadyFn& on_ready = {}, WindowedRecorders* windows = nullptr);

/// `<stem><suffix><ext>` beside `report`: the naming rule for the extra reports a run writes
/// (`-handoff`, `-steady`, `-first-N`).
[[nodiscard]] std::filesystem::path report_sibling(const std::filesystem::path& report, std::string_view suffix);

/// Free-text `notes` for the report.
[[nodiscard]] std::string notes_for(const ConsumerResult& r, const ConsumerConfig& cfg);

}  // namespace lowlat::line
