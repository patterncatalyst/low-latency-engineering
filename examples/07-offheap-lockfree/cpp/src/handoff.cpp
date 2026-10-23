// offheap-handoff: the Ch7 hand-off in C++ (see ../../README.md).
//
// The receive thread decodes each datagram and hands a small record to a decide thread through a
// single-producer single-consumer ring (offheap/handoff.hpp): variant atomic-spsc spins on the
// ring index, atomic-wait parks in std::atomic::wait.
//
// This lane isolates the hand-off. The command channel, the audit journal and the manifest of the
// Java example are not repeated here.
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <format>
#include <optional>
#include <print>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "lowlat/line/cli.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/signals.hpp"
#include "lowlat/offheap/handoff.hpp"
#include "lowlat/offheap/spsc_ring.hpp"

namespace {

namespace line = lowlat::line;
namespace offheap = lowlat::offheap;
using offheap::Wait;
namespace measure = lowlat::measure;

constexpr std::string_view kExample = "07-offheap-lockfree";
constexpr std::uint16_t kPort = 47274;  // the Java lane uses 47270
constexpr std::uint64_t kDefaultWindow = 20'000;

void serve(const line::ConsumerConfig& cfg, Wait wait, std::chrono::milliseconds hold) {
  measure::Recorder rec{cfg.example, cfg.variant};
  std::optional<line::WindowedRecorders> windows;
  if (cfg.window) windows.emplace(cfg.example, cfg.variant, *cfg.window);
  // The ring is 1.5 MiB (65,536 slots of 24 bytes) and lives in this frame on the main thread's
  // stack, well inside the default 8 MiB; the decide thread reaches it through a pointer.
  offheap::Handoff handler{wait, kExample, cfg.variant, cfg.window.value_or(kDefaultWindow), hold};

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
  const auto handoff_report = line::report_sibling(*cfg.report, "-handoff");
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
        const auto ms = line::cli::number<std::int64_t>("--sample-hold-ms", argv[++i]);
        if (ms < 0) throw std::invalid_argument("--sample-hold-ms must be >= 0");
        hold = std::chrono::milliseconds{ms};
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
