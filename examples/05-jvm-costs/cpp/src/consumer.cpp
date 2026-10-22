// Ch5 C++ consumer: the common receive path with the tracker as the handler. There is no JIT here, so
// the first window differs from the steady one only by page faults and cold caches; --window 2000
// reports both for the comparison with the Java lane.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <optional>
#include <print>
#include <string>
#include <string_view>
#include <vector>

#include "lowlat/jvmcosts/tracker.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/signals.hpp"

namespace {

namespace line = lowlat::line;
namespace jvmcosts = lowlat::jvmcosts;

// A line::ParcelHandler: decide, track, complete.
class TrackerHandler {
 public:
  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    const jvmcosts::Decision decision = tracker_.on_parcel(ev);
    ++lane_counts_[decision.lane];
    done.complete(ev);
  }

  [[nodiscard]] std::size_t in_flight_count() const noexcept { return tracker_.in_flight_count(); }
  [[nodiscard]] const std::array<std::uint64_t, line::kLanes>& lane_counts() const noexcept { return lane_counts_; }

 private:
  jvmcosts::Tracker tracker_;
  std::array<std::uint64_t, line::kLanes> lane_counts_{};
};

}  // namespace

int main(int argc, char** argv) {
  using namespace lowlat;
  try {
    // This example's defaults first; a later flag wins in the common parser.
    std::vector<std::string_view> args{"--bind", "127.0.0.1:47250", "--example", "05-jvm-costs", "--variant", "tracker"};
    args.insert(args.end(), argv + 1, argv + argc);
    const line::ConsumerConfig cfg = line::parse_consumer_args(args);
    if (cfg.report) (void)measure::load_profile();

    line::install_stop_handlers();
    measure::Recorder latency{cfg.example, cfg.variant};
    std::optional<line::WindowedRecorders> windows;
    if (cfg.window) windows.emplace(cfg.example, cfg.variant, *cfg.window);

    TrackerHandler handler;
    const line::ConsumerResult result = line::consume_with(
        cfg, line::g_stop, latency, handler,
        [&](int, int) {
          std::println("ready: variant {} on {}", cfg.variant, cfg.bind);
          std::fflush(stdout);  // bound: a script reading a redirected stdout waits on this line
        },
        windows ? &*windows : nullptr);
    std::println("received {}, dropped {}, reordered {} (stopped: {}) in flight {}", result.received, result.dropped,
                 result.reordered, result.stopped_by, handler.in_flight_count());

    latency.print_summary();
    if (windows) {
      windows->first().print_summary();
      windows->steady().print_summary();
    }
    if (cfg.report) {
      const std::string notes = line::notes_for(result, cfg);
      latency.write_report(*cfg.report, notes);
      std::println("report: {}", cfg.report->string());
      if (windows) {
        for (const auto& path : windows->write_reports(*cfg.report, notes)) std::println("report: {}", path.string());
      }
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "jvmcosts-consumer: {}", e.what());
    return EXIT_FAILURE;
  }
}
