// line-consumer: receives the simulator's ParcelEvent datagrams and records
// latency against the belt's schedule. See ../README.md.
#include <atomic>
#include <csignal>
#include <cstdlib>
#include <exception>
#include <print>
#include <string_view>
#include <vector>

#include "lowlat/line/consumer.hpp"

namespace {

// Set from the signal handler, polled by the receive loop. A lock-free atomic
// store is async-signal-safe.
std::atomic<bool> g_stop{false};
static_assert(std::atomic<bool>::is_always_lock_free);

extern "C" void on_signal(int) { g_stop.store(true, std::memory_order_relaxed); }

void install_signal_handlers() {
  struct sigaction sa {};
  sa.sa_handler = on_signal;  // no SA_RESTART: recv must return EINTR
  sigemptyset(&sa.sa_mask);
  sigaction(SIGINT, &sa, nullptr);
  sigaction(SIGTERM, &sa, nullptr);
}

}  // namespace

int main(int argc, char** argv) {
  using namespace lowlat;
  try {
    const std::vector<std::string_view> args(argv + 1, argv + argc);
    for (const auto a : args) {
      if (a == "-h" || a == "--help") {
        std::print("{}", line::consumer_usage());
        return EXIT_SUCCESS;
      }
    }
    const line::ConsumerConfig cfg = line::parse_consumer_args(args);
    // Fail before the run, not after it, if the report cannot be written.
    if (cfg.report) (void)measure::load_profile();

    install_signal_handlers();
    measure::Recorder latency{cfg.example, cfg.variant};
    std::println("line-consumer: listening on {}, SO_RCVBUF requested {} B", cfg.bind, cfg.rcvbuf);
    const line::ConsumerResult result = line::consume(
        cfg, g_stop, latency, [](int, int granted) { std::println("SO_RCVBUF granted: {} B", granted); });
    std::println("received {}, dropped {}, reordered {}, malformed {} (stopped: {})", result.received,
                 result.dropped, result.reordered, result.malformed, result.stopped_by);

    latency.print_summary();
    if (cfg.report) {
      latency.write_report(*cfg.report, line::notes_for(result, cfg));
      std::println("report: {}", cfg.report->string());
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "line-consumer: {}", e.what());
    return EXIT_FAILURE;
  }
}
