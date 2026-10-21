// co-experiment run|probe: Ch3 coordinated omission. See ../../README.md.
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <print>
#include <string_view>
#include <vector>

#include "lowlat/co/experiment.hpp"
#include "lowlat/measure/recorder.hpp"

namespace {

constexpr std::string_view kUsage = R"(usage: co-experiment run   [--bind H:P] [--expect N] [--stall-ms MS] [--stall-seq N]
                           [--suffix S] --out DIR
       co-experiment probe [--out DIR]
)";

void emit(const lowlat::measure::Recorder& r, const std::filesystem::path& dir, std::string_view variant,
          std::string_view notes) {
  r.print_summary();
  r.write_report(dir / std::format("cpp-{}.json", variant), notes);
}

}  // namespace

int main(int argc, char** argv) {
  using namespace lowlat;
  try {
    const std::vector<std::string_view> all(argv + 1, argv + argc);
    if (all.empty() || all[0] == "-h" || all[0] == "--help") {
      std::print("{}", kUsage);
      return all.empty() ? EXIT_FAILURE : EXIT_SUCCESS;
    }
    const std::string_view mode = all[0];
    const co::Config cfg = co::parse_args({all.data() + 1, all.size() - 1});
    (void)measure::load_profile();  // fail before the run, not after it
    std::filesystem::create_directories(cfg.out_dir);

    if (mode == "run") {
      co::Recorders rec{cfg.suffix};
      std::println("listening on {}", cfg.bind);
      std::fflush(stdout);
      const auto dropped = co::run_receive(cfg, rec);
      co::run_closed_loop(cfg, cfg.expect, rec);
      const std::string notes = std::format("stall_ms={} stall_seq={} dropped={}; the stall is a blocking sleep", cfg.stall_ms,
                                            cfg.stall_seq, dropped);
      emit(rec.receipt_time, cfg.out_dir, "receipt-time" + cfg.suffix, notes);
      emit(rec.intended_time, cfg.out_dir, "intended-time" + cfg.suffix, notes);
      emit(rec.closed_loop_corrected, cfg.out_dir, "closed-loop-corrected" + cfg.suffix,
           notes + "; record_corrected, expected interval 1 ms");
      emit(rec.closed_loop_naive, cfg.out_dir, "closed-loop-naive" + cfg.suffix, notes);
    } else if (mode == "probe") {
      co::ClockProbe probe;
      co::run_clock_probe(1'000'000, probe);
      emit(probe.line_monotonic_ns, cfg.out_dir, "clock-read",
           "1e6 back-to-back pairs of lowlat::line::monotonic_ns (clock_gettime CLOCK_MONOTONIC); value = second - first");
      emit(probe.steady_clock, cfg.out_dir, "clock-read-steady_clock",
           "1e6 back-to-back pairs of std::chrono::steady_clock::now; value = second - first");
    } else {
      std::print(stderr, "{}", kUsage);
      return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "co-experiment: {}", e.what());
    return EXIT_FAILURE;
  }
}
