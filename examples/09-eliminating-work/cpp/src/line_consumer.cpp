// eliminating-line: the line consumer with the hub parcel tracker as its handler.
//
// The tracker is preloaded with --preload parcels (the hub: 1,000,000 by default) before the socket is
// bound. Each parcel the simulator sends is then tracked (an insert into the hub table) and the oldest
// preloaded parcel is retired (an erase), so the table stays at hub size for the whole run. The report's
// latency is done_ns - intended_emit_ns, as in every chapter; its runtime.counters carry the exact
// allocations the tracker made on this receive thread (read from the replaced global operator new
// around the two tracker calls, so protobuf decode and the socket are not in them).
//
//   eliminating-line --variant node-map|flat-map [--preload N] [--cpu CPU] [consumer options...]
//
// The consumer options are line-consumer's (--bind, --expect, --report, ...). The report variant is
// "line-node-map" or "line-flat-map".
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <optional>
#include <print>
#include <string>
#include <string_view>
#include <vector>

#include "lowlat/eliminating/alloc_counter.hpp"
#include "lowlat/eliminating/keys.hpp"
#include "lowlat/eliminating/placement.hpp"
#include "lowlat/eliminating/tracker.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/signals.hpp"
#include "lowlat/measure/runtime.hpp"

namespace {

using namespace lowlat;
namespace el = lowlat::eliminating;

constexpr std::uint64_t kPreloadSeed = 2026;

// The per-parcel work: track the scan, retire the oldest hub parcel, count what that allocated.
template <class Tracker>
class TrackerHandler {
 public:
  TrackerHandler(Tracker& tracker, const el::Keys& preloaded) : tracker_(tracker), preloaded_(preloaded) {}

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    const el::Scan scan{.barcode = ev.barcode(),
                        .seq = ev.seq(),
                        .tick = ev.encoder_tick(),
                        .weight_g = ev.weight_g(),
                        .length_mm = static_cast<std::uint16_t>(ev.dims().length_mm()),
                        .width_mm = static_cast<std::uint16_t>(ev.dims().width_mm()),
                        .height_mm = static_cast<std::uint16_t>(ev.dims().height_mm()),
                        .confidence_permille = static_cast<std::uint16_t>(ev.scan_confidence_permille())};
    const el::alloc::Snapshot before = el::alloc::snapshot();
    if (tracker_.track(scan) == el::Tracked::inserted) ++inserted_;
    if (next_retired_ < preloaded_.size()) retired_ += tracker_.erase(preloaded_.text[next_retired_++]);
    const el::alloc::Snapshot used = el::alloc::since(before);
    allocations_ += used.allocations;
    bytes_ += used.bytes;
    done.complete(ev);
  }

  [[nodiscard]] std::uint64_t allocations() const noexcept { return allocations_; }
  [[nodiscard]] std::uint64_t bytes() const noexcept { return bytes_; }
  [[nodiscard]] std::uint64_t inserted() const noexcept { return inserted_; }
  [[nodiscard]] std::uint64_t retired() const noexcept { return retired_; }

 private:
  Tracker& tracker_;
  const el::Keys& preloaded_;
  std::size_t next_retired_ = 0;
  std::uint64_t allocations_ = 0;
  std::uint64_t bytes_ = 0;
  std::uint64_t inserted_ = 0;
  std::uint64_t retired_ = 0;
};

struct Own {
  std::size_t preload = 1'000'000;
  std::optional<int> cpu;
};

// Takes --preload and --cpu out of the arguments; the rest goes to the shared consumer parser.
Own take_own(std::vector<std::string_view>& args) {
  Own own;
  std::vector<std::string_view> rest;
  for (std::size_t i = 0; i < args.size(); ++i) {
    const auto value = [&] {
      if (i + 1 >= args.size()) throw std::invalid_argument("missing value for " + std::string{args[i]});
      return std::string{args[++i]};
    };
    if (args[i] == "--preload") own.preload = std::stoull(value());
    else if (args[i] == "--cpu") own.cpu = std::stoi(value());
    else rest.push_back(args[i]);
  }
  args = std::move(rest);
  return own;
}

template <class Tracker>
int run(const Own& own, line::ConsumerConfig cfg) {
  if (own.cpu) el::pin_current_thread(*own.cpu);
  cfg.variant = "line-" + cfg.variant;

  const el::alloc::Snapshot before_preload = el::alloc::snapshot();
  const el::Keys preloaded = el::make_keys(own.preload, kPreloadSeed);
  Tracker tracker{own.preload + own.preload / 16 + 1'024};
  for (std::size_t i = 0; i < preloaded.size(); ++i) (void)tracker.track(el::scan_of(preloaded, i));
  const el::alloc::Snapshot preload_cost = el::alloc::since(before_preload);
  std::println("preloaded {} parcels", tracker.size());

  line::install_stop_handlers();
  measure::Recorder latency{cfg.example, cfg.variant};
  TrackerHandler<Tracker> handler{tracker, preloaded};
  const line::ConsumerResult result = line::consume_with(
      cfg, line::g_stop, latency, handler, [&](int, int granted) {
        std::println("SO_RCVBUF granted: {} B", granted);
        if (own.cpu) el::announce_placement(*own.cpu, "receive");
        std::println("ready: {} on {}", cfg.variant, cfg.bind);
        std::fflush(stdout);  // bound: a script reading a redirected stdout waits on this line
      });
  std::println("received {}, dropped {}, reordered {}, malformed {} (stopped: {})", result.received, result.dropped,
               result.reordered, result.malformed, result.stopped_by);
  std::println("tracker: {} inserted, {} retired, {} allocations on the receive thread ({} B)", handler.inserted(),
               handler.retired(), handler.allocations(), handler.bytes());
  latency.print_summary();

  if (cfg.report) {
    nlohmann::json runtime;
    runtime["counters"] = measure::counters(
        {{"parcels", static_cast<std::int64_t>(result.completed)},
         {"tracker_allocations", static_cast<std::int64_t>(handler.allocations())},
         {"tracker_allocated_bytes", static_cast<std::int64_t>(handler.bytes())},
         {"preloaded", static_cast<std::int64_t>(own.preload)},
         {"preload_allocated_bytes", static_cast<std::int64_t>(preload_cost.bytes)},
         {"in_flight_at_end", static_cast<std::int64_t>(tracker.size())}});
    if (own.cpu) {
      const int cpus[] = {*own.cpu};
      runtime["placement"] = measure::placement(cpus, true, false);
    }
    latency.write_report(*cfg.report,
                         line::notes_for(result, cfg) + "; hub tracker preloaded, receive thread pinned; " +
                             "allocations counted around track()+erase() on the receive thread",
                         std::nullopt, runtime);
    std::println("report: {}", cfg.report->string());
  }
  return EXIT_SUCCESS;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    std::vector<std::string_view> args(argv + 1, argv + argc);
    for (const auto a : args) {
      if (a == "-h" || a == "--help") {
        std::print("usage: eliminating-line --variant node-map|flat-map [--preload N] [--cpu CPU]\n{}",
                   line::consumer_usage());
        return EXIT_SUCCESS;
      }
    }
    const Own own = take_own(args);
    const line::ConsumerConfig cfg = line::parse_consumer_args(args);
    // Fail before the run, not after it, if the report cannot be written.
    if (cfg.report) (void)measure::load_profile();
    if (cfg.variant == "node-map") return run<el::NodeTracker>(own, cfg);
    if (cfg.variant == "flat-map") return run<el::HotColdTracker>(own, cfg);
    throw std::invalid_argument("--variant must be node-map or flat-map, got " + cfg.variant);
  } catch (const std::exception& e) {
    std::println(stderr, "eliminating-line: {}", e.what());
    return EXIT_FAILURE;
  }
}
