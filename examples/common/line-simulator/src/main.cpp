// line-simulator: open-loop parcel emitter. See README.md.
#include <cstdlib>
#include <exception>
#include <print>
#include <string_view>
#include <vector>

#include "lowlat/line/config.hpp"
#include "lowlat/line/schedule.hpp"
#include "lowlat/line/signals.hpp"
#include "lowlat/line/simulator.hpp"
#include "lowlat/measure/recorder.hpp"

int main(int argc, char** argv) {
  using namespace lowlat;
  try {
    const std::vector<std::string_view> args(argv + 1, argv + argc);
    for (const auto a : args) {
      if (a == "-h" || a == "--help") {
        std::print("{}", line::usage());
        return EXIT_SUCCESS;
      }
    }
    const line::Config cfg = line::parse_args(args);
    // Fail before the run, not after it, if the report cannot be written.
    if (cfg.report) (void)measure::load_profile();

    if (!cfg.quiet) {
      std::println("line-simulator: {} Hz x {} s = {} parcels -> {}, belt {} m/s, seed {}", cfg.rate_hz,
                   cfg.duration_s, line::parcel_count(cfg), cfg.dest, cfg.belt_speed_mps, cfg.seed);
      std::println("scan-to-divert deadline: {:.1f} ms ({} m at {} m/s)",
                   line::scan_to_divert_ms(cfg.scan_to_divert_m, cfg.belt_speed_mps), cfg.scan_to_divert_m,
                   cfg.belt_speed_mps);
    }

    line::install_stop_handlers();
    measure::Recorder lateness{"line-simulator", "emit-lateness"};
    const line::RunResult result = line::run(cfg, line::g_stop, lateness);

    if (!cfg.quiet) {
      std::println("sent {} datagrams, {} send errors{}", result.sent, result.send_errors,
                   result.interrupted ? " (interrupted)" : "");
    }
    lateness.print_summary();
    if (cfg.report) {
      lateness.write_report(*cfg.report);
      if (!cfg.quiet) std::println("report: {}", cfg.report->string());
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "line-simulator: {}", e.what());
    return EXIT_FAILURE;
  }
}
