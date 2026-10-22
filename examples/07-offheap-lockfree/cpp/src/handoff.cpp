// offheap-handoff: the Ch7 hand-off in C++ (see ../../README.md).
//
// The receive thread decodes each datagram and hands a small record to a decide thread through a
// single-producer single-consumer ring. Two ways for the consumer to wait for the next record:
//
//   atomic-spsc   spin on the producer's index (an acquire load) until it moves.
//   atomic-wait   std::atomic::wait on the index; the producer calls notify_one after every push.
//
// The hand-off latency is the time from the receive thread's stamp, taken just before the push,
// to the decide thread's first look at the record. The end-to-end latency is the line's usual
// intended-emit-to-done, with the Completion owned by the decide thread.
//
// This lane isolates the hand-off. The command channel, the audit journal and the manifest of the
// Java example are not repeated here.
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <format>
#include <optional>
#include <print>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "lowlat/line/cli.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/signals.hpp"
#include "lowlat/offheap/spsc_ring.hpp"

namespace {

namespace line = lowlat::line;
namespace offheap = lowlat::offheap;
namespace measure = lowlat::measure;
using line::monotonic_ns;

constexpr std::string_view kExample = "07-offheap-lockfree";
constexpr std::uint16_t kPort = 47274;  // the Java lane uses 47270
constexpr std::uint64_t kDefaultWindow = 20'000;
constexpr std::size_t kSlots = std::size_t{1} << 16;
constexpr std::uint64_t kStop = ~std::uint64_t{0};  // a record with this seq tells the decide thread to end

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
  Handoff(Wait wait, std::string_view variant, std::uint64_t window, std::chrono::milliseconds hold)
      : wait_(wait),
        hold_(hold),
        handoff_(std::string{kExample}, std::format("{}-handoff", variant)),
        handoff_windows_(std::string{kExample}, std::format("{}-handoff", variant), window),
        decide_([this] { decide(); }) {}

  Handoff(const Handoff&) = delete;
  Handoff& operator=(const Handoff&) = delete;
  ~Handoff() { stop_decide(); }

  /// Receive thread.
  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    // The decide thread reads `done_` only after it has popped a record, and the first record is
    // pushed after this store: the ring's release/acquire pair orders it. Written once, never again.
    if (done_ == nullptr) done_ = &done;
    const Scan scan{.seq = ev.seq(), .intended_ns = ev.intended_emit_ns(), .rx_ns = monotonic_ns()};
    if (ring_.try_push(scan)) {
      ++published_;
      if (wait_ == Wait::park) ring_.notify_consumer();
    } else {
      ++overflow_;  // full: the belt does not wait, the count shows the loss
    }
  }

  /// Waits for the decide thread to handle everything, prints the sampling marker, holds, joins.
  void drain(line::Completion&) {
    while (handled_.load(std::memory_order_acquire) < published_) std::this_thread::sleep_for(std::chrono::milliseconds{1});
    std::println("window-end handled={}", handled_.load(std::memory_order_acquire));
    std::fflush(stdout);
    std::this_thread::sleep_for(hold_);
    stop_decide();
  }

  [[nodiscard]] std::uint64_t published() const noexcept { return published_; }
  [[nodiscard]] std::uint64_t overflow() const noexcept { return overflow_; }
  [[nodiscard]] measure::Recorder& handoff() noexcept { return handoff_; }
  [[nodiscard]] line::WindowedRecorders& handoff_windows() noexcept { return handoff_windows_; }

 private:
  void decide() {
    // One parseable line: a script reads /proc/PID/task/TID/status (context switches) from it.
    std::println("decide-thread pid={} tid={}", ::getpid(), ::gettid());
    std::fflush(stdout);
    std::uint64_t handled = 0;
    while (true) {
      std::optional<Scan> scan = ring_.try_pop();
      while (!scan) {
        if (wait_ == Wait::spin) cpu_relax(); else ring_.wait_for_data();
        scan = ring_.try_pop();
      }
      const std::int64_t pickup_ns = monotonic_ns();
      if (scan->seq == kStop) return;
      const std::int64_t handoff_ns = pickup_ns - scan->rx_ns;
      handoff_.record(handoff_ns);
      handoff_windows_.record(scan->seq, handoff_ns);
      done_->complete(scan->seq, scan->intended_ns, monotonic_ns());
      handled_.store(++handled, std::memory_order_release);
    }
  }

  void stop_decide() {
    if (!decide_.joinable()) return;
    while (!ring_.try_push(Scan{.seq = kStop})) std::this_thread::yield();
    if (wait_ == Wait::park) ring_.notify_consumer();
    decide_.join();
  }

  Wait wait_;
  std::chrono::milliseconds hold_;
  offheap::SpscRing<Scan, kSlots> ring_;
  measure::Recorder handoff_;
  line::WindowedRecorders handoff_windows_;
  line::Completion* done_ = nullptr;
  std::uint64_t published_ = 0;  // receive thread only
  std::uint64_t overflow_ = 0;   // receive thread only
  std::atomic<std::uint64_t> handled_ = 0;
  std::jthread decide_;  // last member: starts after everything it uses exists
};

[[nodiscard]] std::filesystem::path sibling(const std::filesystem::path& report, std::string_view suffix) {
  return report.parent_path() / std::format("{}{}{}", report.stem().string(), suffix, report.extension().string());
}

void serve(const line::ConsumerConfig& cfg, Wait wait, std::chrono::milliseconds hold) {
  measure::Recorder rec{cfg.example, cfg.variant};
  std::optional<line::WindowedRecorders> windows;
  if (cfg.window) windows.emplace(cfg.example, cfg.variant, *cfg.window);
  Handoff handler{wait, cfg.variant, cfg.window.value_or(kDefaultWindow), hold};

  const auto result = line::consume_with(
      cfg, line::g_stop, rec, handler,
      [&](int, int) {
        std::println("offheap-handoff: variant {} listening on {}", cfg.variant, cfg.bind);
        std::fflush(stdout);  // bound: a script reading a redirected stdout waits on this line
      },
      windows ? &*windows : nullptr);

  std::println("received {}, dropped {}, reordered {} published {} overflow {} (stopped: {})", result.received,
               result.dropped, result.reordered, handler.published(), handler.overflow(), result.stopped_by);
  const auto notes = std::format("handoff={}; published={}; overflow={}; reordered={}; rcvbuf_granted={}",
                                 wait == Wait::spin ? "atomic-spsc" : "atomic-wait", handler.published(),
                                 handler.overflow(), result.reordered, result.granted_rcvbuf);
  rec.print_summary();
  handler.handoff().print_summary();
  if (!cfg.report) return;
  rec.write_report(*cfg.report, notes);
  const auto handoff_report = sibling(*cfg.report, "-handoff");
  handler.handoff().write_report(handoff_report, notes);
  if (windows) {
    windows->write_reports(*cfg.report, notes);
    handler.handoff_windows().write_reports(handoff_report, notes);
  }
  std::println("report: {}", cfg.report->string());
}

}  // namespace

int main(int argc, char** argv) {
  using namespace lowlat;
  try {
    // --sample-hold-ms is the only flag the common consumer does not know; the rest, with this
    // example's defaults first (a later flag wins), go to the common parser.
    const std::string bind = std::format("127.0.0.1:{}", kPort);
    const std::string window = std::to_string(kDefaultWindow);
    std::vector<std::string_view> args{"--bind",    bind,           "--example", kExample,
                                       "--variant", "atomic-spsc", "--window",  window};
    std::chrono::milliseconds hold{0};
    for (int i = 1; i < argc; ++i) {
      if (std::string_view{argv[i]} == "--sample-hold-ms" && i + 1 < argc) {
        hold = std::chrono::milliseconds{line::cli::number<std::int64_t>("--sample-hold-ms", argv[++i])};
      } else if (std::string_view{argv[i]} == "-h" || std::string_view{argv[i]} == "--help") {
        std::print("usage: offheap-handoff [--variant atomic-spsc|atomic-wait] [--sample-hold-ms MS]\n{}",
                   line::consumer_usage());
        return EXIT_SUCCESS;
      } else {
        args.emplace_back(argv[i]);
      }
    }
    const line::ConsumerConfig cfg = line::parse_consumer_args(args);
    if (cfg.report) (void)measure::load_profile();

    line::install_stop_handlers();
    if (cfg.variant == "atomic-spsc") {
      serve(cfg, Wait::spin, hold);
    } else if (cfg.variant == "atomic-wait") {
      serve(cfg, Wait::park, hold);
    } else {
      throw std::invalid_argument("--variant: atomic-spsc | atomic-wait");
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "offheap-handoff: {}", e.what());
    return EXIT_FAILURE;
  }
}
