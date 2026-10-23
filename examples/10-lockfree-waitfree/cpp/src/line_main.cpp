// lockfree-line: the Ch10 line run in C++ (see ../README.md).
//
// Four tunnel cameras (four simulator instances, one UDP port each) feed one tracker. One receive
// thread per camera decodes its datagrams and publishes each scan into a shared multi-producer log,
// claiming the slot with a std::mutex (--variant mutex) or a fetch_add (--variant fetch-add); the
// tracker thread reads the log in order, decides the lane, sends the divert command on the separate
// command socket and completes the parcel. The five threads are pinned to distinct cores.
//
//   lockfree-line --variant mutex|fetch-add [--base-port 47300] [--expect 50000] [--cpus A,B,C,D,E]
//                 [--hold-ms N] [--report FILE]
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <format>
#include <map>
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
#include "lowlat/line/v1/divert.pb.h"
#include "lowlat/lockfree/claim.hpp"
#include "lowlat/lockfree/claim_log.hpp"
#include "lowlat/lockfree/command.hpp"
#include "lowlat/lockfree/options.hpp"
#include "lowlat/lockfree/placement.hpp"
#include "lowlat/lockfree/report_util.hpp"
#include "lowlat/measure/recorder.hpp"
#include "lowlat/measure/runtime.hpp"

namespace {

namespace lf = lowlat::lockfree;
namespace line = lowlat::line;
namespace measure = lowlat::measure;

constexpr std::string_view kExample = "10-lockfree-waitfree";
constexpr int kCameras = 4;
constexpr std::size_t kLogSlots = 1U << 14;
constexpr std::uint32_t kMinConfidencePermille = 500;  // below this the read goes to the exception lane
constexpr std::uint64_t kDivertDistanceTicks = 1'200;  // 1.2 m at the simulator's 1000 pulses per metre

/// One scan on its way from a camera's receive thread to the tracker.
struct Scan {
  line::Completion* done = nullptr;  ///< the camera's completion; null marks the end of the run
  std::uint64_t seq = 0;
  std::int64_t intended_ns = 0;
  std::uint64_t encoder_tick = 0;
  std::uint32_t camera = 0;
  std::uint32_t confidence_permille = 0;
  std::array<char, 24> barcode{};
};
static_assert(std::is_trivially_copyable_v<Scan>);

/// A camera's receive-side hook: publish the scan, count it, and wait for the tracker at the end.
template <lf::SequenceClaim Claim>
class CameraHandler {
 public:
  CameraHandler(std::uint32_t camera, lf::ClaimLog<Claim, Scan>& log, std::atomic<std::uint64_t>& handled)
      : camera_{camera}, log_{&log}, handled_{&handled} {}

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    Scan scan;
    scan.done = &done;
    scan.seq = ev.seq();
    scan.intended_ns = ev.intended_emit_ns();
    scan.encoder_tick = ev.encoder_tick();
    scan.camera = camera_;
    scan.confidence_permille = ev.scan_confidence_permille();
    std::memcpy(scan.barcode.data(), ev.barcode().data(), std::min(ev.barcode().size(), scan.barcode.size() - 1));
    log_->publish(log_->claim(stats_), scan, stats_);
    ++published_;
  }

  /// Called when the receive loop ends: the tracker owns the Completion until it has handled everything.
  void drain(line::Completion&) {
    while (handled_->load(std::memory_order_acquire) < published_) std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }

  [[nodiscard]] std::uint64_t published() const noexcept { return published_; }
  lf::ClaimStats& stats() noexcept { return stats_; }

 private:
  std::uint32_t camera_;
  lf::ClaimLog<Claim, Scan>* log_;
  std::atomic<std::uint64_t>* handled_;
  lf::ClaimStats stats_;
  std::uint64_t published_ = 0;
};

using lf::Options;

template <lf::SequenceClaim Claim>
int run(const Options& o, const std::string& variant) {
  const int base_port = static_cast<int>(o.number("base-port", 47300));
  const std::uint64_t per_camera = o.number("expect", 50'000);
  std::vector<int> cpus(kCameras + 1, -1);
  if (const std::string list = o.text("cpus", ""); !list.empty()) {
    cpus = lf::parse_cpu_list(list);
    if (cpus.size() < kCameras + 1) throw std::invalid_argument(std::format("--cpus needs {} CPUs", kCameras + 1));
    cpus.resize(kCameras + 1);
  }
  lf::Gate gate{kCameras + 1, std::chrono::milliseconds{o.number("hold-ms", 0)}};
  line::install_stop_handlers();

  lf::ClaimLog<Claim, Scan> log{kLogSlots};
  std::array<std::atomic<std::uint64_t>, kCameras> handled{};
  std::vector<measure::Recorder> cameras;
  std::vector<CameraHandler<Claim>> handlers;
  std::vector<line::ConsumerConfig> configs;
  std::vector<line::ConsumerResult> results(kCameras);
  cameras.reserve(kCameras);
  handlers.reserve(kCameras);
  for (int c = 0; c < kCameras; ++c) {
    cameras.emplace_back(std::string{kExample}, variant);
    handlers.emplace_back(static_cast<std::uint32_t>(c), log, handled[c]);
    line::ConsumerConfig cfg;
    cfg.bind = std::format("127.0.0.1:{}", base_port + c);
    cfg.expect = per_camera;
    cfg.idle_timeout_ms = 5000;
    cfg.example = std::string{kExample};
    cfg.variant = variant;
    configs.push_back(std::move(cfg));
  }

  lf::DivertListener diverter{std::string{kExample}, variant};
  lf::CommandSender commands{diverter.port()};
  measure::Recorder end_to_end{std::string{kExample}, variant};
  std::uint64_t handled_total = 0, exception_lane = 0;  // the tracker's, read after join
  lf::ClaimStats end_stats;  // main's, for the end marker

  {
    std::vector<std::jthread> threads;
    threads.reserve(kCameras + 1);
    for (int c = 0; c < kCameras; ++c) {
      threads.emplace_back([&, c] {
        gate.worker_ready(cpus[c], std::format("camera-{}", c));
        results[c] = line::consume_with(
            configs[c], line::g_stop, cameras[c], handlers[c],
            [&](int port, int) { std::println("line: camera {} listening on {}", c, port); std::fflush(stdout); });
      });
    }
    threads.emplace_back([&] {
      gate.worker_ready(cpus[kCameras], "tracker");
      std::array<std::uint64_t, kCameras> per_camera_handled{};
      for (std::uint64_t seq = 0;; ++seq) {
        std::int64_t waited = 0;
        const Scan scan = log.read(seq, waited);
        log.consumed(seq);
        if (scan.done == nullptr) break;
        const bool doubtful = scan.confidence_permille < kMinConfidencePermille;
        const unsigned lane = line::lane_for(std::string_view{scan.barcode.data()});
        line::v1::DivertCommand command;
        command.set_seq(scan.seq);
        command.set_lane(doubtful ? line::v1::LANE_EXCEPTION : static_cast<line::v1::Lane>(line::v1::LANE_1 + lane));
        command.set_deadline_encoder_tick(scan.encoder_tick + kDivertDistanceTicks);
        command.set_decided_ns(line::monotonic_ns());
        commands.send(command);
        const std::int64_t done_ns = line::monotonic_ns();
        scan.done->complete(scan.seq, scan.intended_ns, done_ns);
        end_to_end.record(done_ns - scan.intended_ns);
        if (doubtful) ++exception_lane;
        ++handled_total;
        handled[scan.camera].store(++per_camera_handled[scan.camera], std::memory_order_release);
      }
    });
    gate.release();
    for (int c = 0; c < kCameras; ++c) threads[c].join();
    Scan end;  // done == nullptr
    log.publish(log.claim(end_stats), end, end_stats);
  }  // the tracker is joined

  for (int i = 0; i < 5000 && diverter.received() < handled_total; ++i) std::this_thread::sleep_for(std::chrono::milliseconds{1});
  measure::Recorder& divert = diverter.stop_and_take();

  std::uint64_t published = 0, dropped = 0;
  lf::ClaimStats claim_totals;
  for (int c = 0; c < kCameras; ++c) {
    published += handlers[c].published();
    dropped += results[c].dropped;
    claim_totals.claims += handlers[c].stats().claims;
    claim_totals.steps += handlers[c].stats().steps;
  }
  end_to_end.add_dropped(dropped);
  std::println("line: handled {} of {} published, dropped {}, divert commands received {}", handled_total, published, dropped,
               diverter.received());
  end_to_end.print_summary();

  const std::string report_path = o.text("report", "");
  if (report_path.empty()) return 0;
  nlohmann::json placement = nlohmann::json::object();
  if (std::ranges::all_of(cpus, [](int c) { return c >= 0; })) placement = lf::placement_of(cpus);
  const std::string notes = std::format(
      "line; cameras={}; expect_per_camera={}; published={}; handled={}; exception_lane={}; divert_received={}; log_slots={}; claim={}",
      kCameras, per_camera, published, handled_total, exception_lane, diverter.received(), kLogSlots, variant);
  nlohmann::json runtime;
  if (!placement.empty()) runtime["placement"] = placement;
  runtime["counters"] = measure::counters({{"handled", static_cast<std::int64_t>(handled_total)},
                                           {"published", static_cast<std::int64_t>(published)},
                                           {"dropped", static_cast<std::int64_t>(dropped)},
                                           {"divert_received", static_cast<std::int64_t>(diverter.received())},
                                           {"claim_steps", static_cast<std::int64_t>(claim_totals.steps)}});
  const std::filesystem::path report{report_path};
  end_to_end.write_report(report, notes, std::nullopt, runtime);
  std::println("report: {}", report.string());
  nlohmann::json side;
  if (!placement.empty()) side["placement"] = placement;
  for (int c = 0; c < kCameras; ++c) {
    const auto path = line::report_sibling(report, std::format("-camera{}", c));
    cameras[c].write_report(path, std::format("{}; camera={}", notes, c), std::nullopt, side);
    std::println("report: {}", path.string());
  }
  const auto divert_path = line::report_sibling(report, "-divert");
  divert.write_report(divert_path, notes + "; divert latency is the tracker's decision to the command's arrival", std::nullopt, side);
  std::println("report: {}", divert_path.string());
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const Options o{argc, argv, 1};
    const std::string variant = o.text("variant", "");
    if (!o.text("report", "").empty()) (void)measure::load_profile();
    if (variant == "mutex") return run<lf::MutexClaim>(o, variant);
    if (variant == "fetch-add") return run<lf::FetchAddClaim>(o, variant);
    throw std::invalid_argument("--variant: mutex | fetch-add");
  } catch (const std::exception& e) {
    std::println(stderr, "lockfree-line: {}", e.what());
    return EXIT_FAILURE;
  }
}
