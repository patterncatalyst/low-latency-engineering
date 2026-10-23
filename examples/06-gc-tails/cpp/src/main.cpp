// gc-tails-consumer: the Ch6 C++ lane (see ../../README.md).
//
// The same tracker workload as the Java lane, but the cost under test is destruction: the wave of
// manifest entries that a shift retires is freed on the hot thread (bulk-free), on a reclaimer
// thread (deferred-free), or not at all inside the run (no-free, the control).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <format>
#include <print>
#include <string>
#include <string_view>
#include <vector>

#include <nlohmann/json.hpp>

#include "lowlat/gctails/tracker.hpp"
#include "lowlat/line/cli.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/signals.hpp"

namespace {

namespace line = lowlat::line;
namespace gc = lowlat::gctails;

struct Options {
  gc::Settings settings;
  std::size_t warmup = 30'000;
  std::vector<std::string_view> rest;  // for the common consumer parser
};

// The flags the common parser does not know; everything else is passed on, after this example's defaults.
Options split_args(int argc, char** argv) {
  Options o;
  o.rest = {"--bind", "127.0.0.1:47262", "--example", "06-gc-tails", "--variant", "bulk-free"};
  for (int i = 1; i < argc; ++i) {
    const std::string_view flag{argv[i]};
    const auto value = [&] {
      if (i + 1 >= argc) line::cli::fail(std::format("option {} needs a value", flag));
      return std::string_view{argv[++i]};
    };
    if (flag == "--rate") o.settings.rate = line::cli::number<std::uint64_t>(flag, value());
    else if (flag == "--wave-parcels") o.settings.wave_parcels = line::cli::number<std::size_t>(flag, value());
    else if (flag == "--entry-bytes") o.settings.entry_bytes = line::cli::number<std::size_t>(flag, value());
    else if (flag == "--in-flight-ms") o.settings.in_flight_ms = line::cli::number<int>(flag, value());
    else if (flag == "--warm-up") o.warmup = line::cli::number<std::size_t>(flag, value());
    else o.rest.push_back(flag);
  }
  if (o.settings.wave_parcels == 0 || o.settings.rate == 0) line::cli::fail("--rate and --wave-parcels must be > 0");
  return o;
}

// The per-parcel hook: the tracker, then done.
class TrackerHandler {
 public:
  explicit TrackerHandler(gc::Tracker& tracker) : tracker_(&tracker) {}

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    lane_sink_ += tracker_->track(ev.barcode(), ev.seq());
    done.complete(ev);
  }

  [[nodiscard]] unsigned lane_sink() const noexcept { return lane_sink_; }

 private:
  gc::Tracker* tracker_;
  unsigned lane_sink_ = 0;
};

// Runs synthetic parcels through the tracker so the first window is not the first touch of every page and cache line.
void warm_up(gc::Tracker& tracker, std::size_t parcels) {
  for (std::size_t i = 0; i < parcels; ++i) (void)tracker.track(gc::synthetic_barcode(i), i);
}

}  // namespace

int main(int argc, char** argv) {
  using namespace lowlat;
  try {
    const Options options = split_args(argc, argv);
    const line::ConsumerConfig cfg = line::parse_consumer_args(options.rest);
    const auto policy = gc::parse_policy(cfg.variant);
    if (!policy) line::cli::fail("--variant: bulk-free | deferred-free | no-free");
    if (cfg.report) (void)measure::load_profile();

    line::install_stop_handlers();
    gc::Tracker tracker{*policy, options.settings};
    warm_up(tracker, options.warmup);
    TrackerHandler handler{tracker};

    measure::Recorder rec{cfg.example, cfg.variant};
    const auto result = line::consume_with(cfg, line::g_stop, rec, handler, [&](int, int) {
      std::println("gc-tails-consumer: variant {} on {}", cfg.variant, cfg.bind);
      std::fflush(stdout);  // bound: a script reading a redirected stdout waits on this line
    });
    tracker.finish();  // joins the reclaimer, outside the measured loop

    std::println("received {}, dropped {}, reordered {} (stopped: {}) [{}]", result.received, result.dropped,
                 result.reordered, result.stopped_by, handler.lane_sink() & 1U);
    rec.print_summary();
    if (cfg.report) {
      const auto notes = std::format(
          "waves_closed={}; destroyed_inline={}; reclaimed={}; retained={}; wave_parcels={}; entry_bytes={}; "
          "warmup={}; reordered={}",
          tracker.waves_closed(), tracker.destroyed_inline(), tracker.reclaimed(), tracker.retained(),
          options.settings.wave_parcels, options.settings.entry_bytes, options.warmup, result.reordered);
      const nlohmann::json runtime{{"gc", {{"name", "none: malloc/free"}, {"flags", {std::string{gc::name(*policy)}}}}}};
      rec.write_report(*cfg.report, notes, std::nullopt, runtime);
    }
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "gc-tails-consumer: {}", e.what());
    return EXIT_FAILURE;
  }
}
