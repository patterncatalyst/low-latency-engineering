// line-consumer: receives the simulator's ParcelEvent datagrams and records
// latency against the belt's schedule. See ../README.md.
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <optional>
#include <print>
#include <string_view>
#include <vector>

#include "lowlat/line/consumer.hpp"
#include "lowlat/line/signals.hpp"

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

    line::install_stop_handlers();
    measure::Recorder latency{cfg.example, cfg.variant};
    std::optional<line::WindowedRecorders> windows;
    if (cfg.window) windows.emplace(cfg.example, cfg.variant, *cfg.window);
    std::println("line-consumer: listening on {}, SO_RCVBUF requested {} B", cfg.bind, cfg.rcvbuf);
    const line::ConsumerResult result = line::consume(
        cfg, line::g_stop, latency, [](int, int granted) {
          std::println("SO_RCVBUF granted: {} B", granted);
          // The socket is bound: flush so a script reading a redirected stdout can wait on this line.
          std::fflush(stdout);
        },
        windows ? &*windows : nullptr);
    std::println("received {}, dropped {}, reordered {}, malformed {} (stopped: {})", result.received,
                 result.dropped, result.reordered, result.malformed, result.stopped_by);

    latency.print_summary();
    if (windows) {
      windows->first().print_summary();
      windows->steady().print_summary();
    }
    if (cfg.report) {
      latency.write_report(*cfg.report, line::notes_for(result, cfg));
      std::println("report: {}", cfg.report->string());
      if (windows) {
        for (const auto& path : windows->write_reports(*cfg.report, line::notes_for(result, cfg))) {
          std::println("report: {}", path.string());
        }
      }
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "line-consumer: {}", e.what());
    return EXIT_FAILURE;
  }
}
