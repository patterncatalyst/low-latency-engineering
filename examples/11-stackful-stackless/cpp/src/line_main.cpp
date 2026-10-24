// tasks-line: the Ch11 line run in C++ (see ../README.md).
//
// One simulator instance feeds a UDP port. For every scan the receive thread starts a lookup task that waits
// 2 ms (the warehouse management system's answer, a timer in this process), then decides the lane, sends the
// divert command on the separate command socket and completes the parcel. Who holds the wait is the variant:
//   os-thread  a thread per lookup (it sleeps; threads are detached and counted)
//   fiber      a Boost.Fiber per lookup on one executor thread, fed through a buffered_channel
//   coroutine  an Asio awaitable per lookup on one io_context thread
//
//   tasks-line --variant os-thread|fiber|coroutine [--base-port 47310] [--expect 200000] [--cpus A,B]
//              [--hold-ms N] [--report FILE]
#include <boost/asio/awaitable.hpp>
#include <boost/asio/co_spawn.hpp>
#include <boost/asio/detached.hpp>
#include <boost/asio/executor_work_guard.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/steady_timer.hpp>
#include <boost/asio/this_coro.hpp>
#include <boost/asio/use_awaitable.hpp>
#include <boost/context/protected_fixedsize_stack.hpp>
#include <boost/fiber/all.hpp>

#include <sched.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <format>
#include <mutex>
#include <print>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>
#include <vector>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/signals.hpp"
#include "lowlat/line/v1/divert.pb.h"
#include "lowlat/measure/recorder.hpp"
#include "lowlat/measure/runtime.hpp"
#include "lowlat/tasks/divert.hpp"
#include "lowlat/tasks/options.hpp"
#include "lowlat/tasks/placement.hpp"
#include "lowlat/tasks/workloads.hpp"

namespace {

namespace asio = boost::asio;
namespace line = lowlat::line;
namespace measure = lowlat::measure;
namespace tasks = lowlat::tasks;
using namespace std::chrono_literals;

constexpr std::string_view kExample = "11-stackful-stackless";
constexpr auto kLookupWait = 2ms;                      // the WMS sort-plan lookup
constexpr std::uint32_t kMinConfidencePermille = 500;  // below this the read goes to the exception lane
constexpr std::uint64_t kDivertDistanceTicks = 1'200;  // 1.2 m at the simulator's 1000 pulses per metre

/// One scan on its way to a lookup task.
struct Scan {
  std::uint64_t seq = 0;
  std::int64_t intended_ns = 0;
  std::uint64_t encoder_tick = 0;
  std::uint32_t confidence_permille = 0;
  std::array<char, 24> barcode{};

  static Scan of(const line::v1::ParcelEvent& ev) {
    Scan s;
    s.seq = ev.seq();
    s.intended_ns = ev.intended_emit_ns();
    s.encoder_tick = ev.encoder_tick();
    s.confidence_permille = ev.scan_confidence_permille();
    std::memcpy(s.barcode.data(), ev.barcode().data(), std::min(ev.barcode().size(), s.barcode.size() - 1));
    return s;
  }
};
static_assert(std::is_trivially_copyable_v<Scan>);

/// The decision after the wait: lane lookup, divert command out on the command socket. Thread-safe.
class Decider {
 public:
  explicit Decider(int command_port) : commands_{command_port} {}

  /// Returns the monotonic time at which the command left.
  std::int64_t decide(const Scan& scan) {
    const bool doubtful = scan.confidence_permille < kMinConfidencePermille;
    const unsigned lane = line::lane_for(std::string_view{scan.barcode.data()});
    line::v1::DivertCommand command;
    command.set_seq(scan.seq);
    command.set_lane(doubtful ? line::v1::LANE_EXCEPTION : static_cast<line::v1::Lane>(line::v1::LANE_1 + lane));
    command.set_deadline_encoder_tick(scan.encoder_tick + kDivertDistanceTicks);
    command.set_decided_ns(line::monotonic_ns());
    commands_.send(command);
    if (doubtful) exception_lane_.fetch_add(1, std::memory_order_relaxed);
    decided_.fetch_add(1, std::memory_order_relaxed);
    return line::monotonic_ns();
  }

  [[nodiscard]] std::uint64_t decided() const { return decided_.load(std::memory_order_acquire); }
  [[nodiscard]] std::uint64_t exception_lane() const { return exception_lane_.load(std::memory_order_relaxed); }

 private:
  tasks::CommandSender commands_;
  std::atomic<std::uint64_t> decided_{0};
  std::atomic<std::uint64_t> exception_lane_{0};
};

void poll_until_zero(const std::atomic<std::uint64_t>& counter) {
  while (counter.load(std::memory_order_acquire) != 0) std::this_thread::sleep_for(1ms);
}

// ---- os-thread --------------------------------------------------------------------------------------------------------

class ThreadHandler {
 public:
  explicit ThreadHandler(Decider& decider) : decider_{&decider} {
    // The receive thread is pinned and std::thread inherits its mask, so each lookup thread widens its own
    // mask back to what the process was allowed before the pin.
    ::sched_getaffinity(0, sizeof allowed_, &allowed_);
  }
  void start(tasks::Gate&, int) {}

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    if (done_ == nullptr) done_ = &done;
    spawned_.fetch_add(1, std::memory_order_relaxed);
    outstanding_.fetch_add(1, std::memory_order_acq_rel);
    // A thread per lookup. Completion is single-writer, so the threads take turns at it under a mutex.
    std::thread{[this, scan = Scan::of(ev)] {
      ::sched_setaffinity(0, sizeof allowed_, &allowed_);
      std::this_thread::sleep_for(kLookupWait);
      const std::int64_t done_ns = decider_->decide(scan);
      {
        const std::scoped_lock lock{mutex_};
        done_->complete(scan.seq, scan.intended_ns, done_ns);
      }
      outstanding_.fetch_sub(1, std::memory_order_acq_rel);
    }}.detach();
  }

  void drain(line::Completion&) { poll_until_zero(outstanding_); }
  [[nodiscard]] std::uint64_t spawned() const { return spawned_.load(std::memory_order_relaxed); }

 private:
  Decider* decider_;
  cpu_set_t allowed_{};
  line::Completion* done_ = nullptr;
  std::mutex mutex_;
  std::atomic<std::uint64_t> outstanding_{0};
  std::atomic<std::uint64_t> spawned_{0};
};

// ---- fiber ----------------------------------------------------------------------------------------------------------------

class FiberHandler {
 public:
  explicit FiberHandler(Decider& decider) : decider_{&decider} {}

  void start(tasks::Gate& gate, int cpu) {
    executor_ = std::thread{[this, &gate, cpu] {
      gate.worker_ready(cpu, "fibers");
      boost::context::protected_fixedsize_stack stack{tasks::kFiberStackBytes};
      std::size_t live = 0;  // touched by this thread only: every fiber runs on it
      Scan scan;
      while (channel_.pop(scan) == boost::fibers::channel_op_status::success) {
        ++live;
        boost::fibers::fiber{std::allocator_arg, stack, [this, scan, &live] {
          boost::this_fiber::sleep_for(kLookupWait);
          const std::int64_t done_ns = decider_->decide(scan);
          done_->complete(scan.seq, scan.intended_ns, done_ns);
          --live;
        }}.detach();
      }
      while (live != 0) boost::this_fiber::sleep_for(1ms);
    }};
  }

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    if (done_ == nullptr) done_ = &done;  // published to the executor by the channel push
    spawned_.fetch_add(1, std::memory_order_relaxed);
    channel_.push(Scan::of(ev));
  }

  void drain(line::Completion&) {
    channel_.close();
    executor_.join();  // the join publishes the executor's completions to the receive thread
  }
  [[nodiscard]] std::uint64_t spawned() const { return spawned_.load(std::memory_order_relaxed); }

 private:
  Decider* decider_;
  line::Completion* done_ = nullptr;
  boost::fibers::buffered_channel<Scan> channel_{1U << 14};
  std::thread executor_;
  std::atomic<std::uint64_t> spawned_{0};
};

// ---- coroutine ------------------------------------------------------------------------------------------------------------

class CoroutineHandler {
 public:
  explicit CoroutineHandler(Decider& decider) : decider_{&decider}, guard_{asio::make_work_guard(ctx_)} {}

  void start(tasks::Gate& gate, int cpu) {
    executor_ = std::thread{[this, &gate, cpu] {
      gate.worker_ready(cpu, "coroutines");
      ctx_.run();
    }};
  }

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    if (done_ == nullptr) done_ = &done;
    spawned_.fetch_add(1, std::memory_order_relaxed);
    outstanding_.fetch_add(1, std::memory_order_acq_rel);
    asio::co_spawn(ctx_, lookup(Scan::of(ev)), asio::detached);
  }

  void drain(line::Completion&) {
    poll_until_zero(outstanding_);
    guard_.reset();
    executor_.join();
  }
  [[nodiscard]] std::uint64_t spawned() const { return spawned_.load(std::memory_order_relaxed); }

 private:
  asio::awaitable<void> lookup(Scan scan) {
    asio::steady_timer timer{co_await asio::this_coro::executor, kLookupWait};
    co_await timer.async_wait(asio::use_awaitable);
    const std::int64_t done_ns = decider_->decide(scan);
    done_->complete(scan.seq, scan.intended_ns, done_ns);
    outstanding_.fetch_sub(1, std::memory_order_acq_rel);
  }

  Decider* decider_;
  line::Completion* done_ = nullptr;
  asio::io_context ctx_{1};
  asio::executor_work_guard<asio::io_context::executor_type> guard_;
  std::thread executor_;
  std::atomic<std::uint64_t> outstanding_{0};
  std::atomic<std::uint64_t> spawned_{0};
};

// ---- the run -----------------------------------------------------------------------------------------------------------------

template <class Handler>
int run(const tasks::Options& o, const std::string& variant, bool has_executor) {
  const auto base_port = o.number("base-port", 47310);
  const auto expect = o.number("expect", 200'000);
  const auto hold = o.number("hold-ms", 0);
  if (!base_port || !expect || !hold) {
    std::println(stderr, "tasks-line: {}", !base_port ? base_port.error() : !expect ? expect.error() : hold.error());
    return EXIT_FAILURE;
  }
  std::vector<int> cpus(has_executor ? 2 : 1, -1);
  if (const std::string list = o.text("cpus", ""); !list.empty()) {
    auto parsed = tasks::parse_cpu_list(list);
    if (!parsed || parsed->size() < cpus.size()) {
      std::println(stderr, "tasks-line: {}", parsed ? std::format("--cpus needs {} CPUs", cpus.size()) : parsed.error());
      return EXIT_FAILURE;
    }
    cpus.assign(parsed->begin(), parsed->begin() + static_cast<std::ptrdiff_t>(cpus.size()));
  }
  line::install_stop_handlers();

  tasks::DivertListener diverter{std::string{kExample}, variant};
  Decider decider{diverter.port()};
  Handler handler{decider};
  measure::Recorder end_to_end{std::string{kExample}, variant};
  line::ConsumerConfig cfg;
  cfg.bind = std::format("127.0.0.1:{}", *base_port);
  cfg.expect = *expect;
  cfg.idle_timeout_ms = 5000;
  cfg.example = std::string{kExample};
  cfg.variant = variant;

  tasks::Gate gate{has_executor ? 2 : 1, std::chrono::milliseconds{*hold}};
  line::ConsumerResult result;
  std::string failure;
  handler.start(gate, cpus.back());
  std::thread receive{[&] {
    gate.worker_ready(cpus.front(), "receive");
    try {
      result = line::consume_with(cfg, line::g_stop, end_to_end, handler,
                                  [](int port, int) { std::println("line: listening on {}", port); std::fflush(stdout); });
    } catch (const std::exception& e) {
      failure = e.what();
    }
  }};
  gate.release();
  receive.join();
  if (auto pin = gate.error()) failure = *pin;
  if (!failure.empty()) {
    std::println(stderr, "tasks-line: {}", failure);
    return EXIT_FAILURE;
  }
  for (int i = 0; i < 5000 && diverter.received() < decider.decided(); ++i) std::this_thread::sleep_for(1ms);
  measure::Recorder& divert = diverter.stop_and_take();

  std::println("line: received {} of {}, dropped {}, decided {}, divert commands received {}", result.received, *expect, result.dropped,
               decider.decided(), diverter.received());
  end_to_end.print_summary();

  const std::string report_path = o.text("report", "");
  if (report_path.empty()) return EXIT_SUCCESS;
  (void)measure::load_profile();
  const std::vector<int> pinned = gate.cpus();
  nlohmann::json placement = nlohmann::json::object();
  if (!pinned.empty()) placement = tasks::placement_of(pinned);
  const std::string notes = std::format(
      "line; expect={}; received={}; decided={}; exception_lane={}; divert_received={}; lookup_wait_ms={}; model={}", *expect, result.received,
      decider.decided(), decider.exception_lane(), diverter.received(), kLookupWait.count(), variant);
  nlohmann::json runtime;
  if (!placement.empty()) runtime["placement"] = placement;
  runtime["counters"] = measure::counters({{"received", static_cast<std::int64_t>(result.received)},
                                           {"dropped", static_cast<std::int64_t>(result.dropped)},
                                           {"decided", static_cast<std::int64_t>(decider.decided())},
                                           {"tasks_started", static_cast<std::int64_t>(handler.spawned())},
                                           {"divert_received", static_cast<std::int64_t>(diverter.received())},
                                           {"start_skew_ns", gate.start_skew_ns()}});
  const std::filesystem::path report{report_path};
  end_to_end.write_report(report, notes, std::nullopt, runtime);
  std::println("report: {}", report.string());
  nlohmann::json side;
  if (!placement.empty()) side["placement"] = placement;
  const auto divert_path = line::report_sibling(report, "-divert");
  divert.write_report(divert_path, notes + "; divert latency is the decision to the command's arrival", std::nullopt, side);
  std::println("report: {}", divert_path.string());
  return EXIT_SUCCESS;
}

}  // namespace

int main(int argc, char** argv) {
  auto opts = tasks::Options::parse(argc, argv, 1);
  if (!opts) {
    std::println(stderr, "tasks-line: {}", opts.error());
    return EXIT_FAILURE;
  }
  const std::string variant = opts->text("variant", "");
  try {
    if (variant == "os-thread") return run<ThreadHandler>(*opts, variant, false);
    if (variant == "fiber") return run<FiberHandler>(*opts, variant, true);
    if (variant == "coroutine") return run<CoroutineHandler>(*opts, variant, true);
    std::println(stderr, "tasks-line: --variant: os-thread | fiber | coroutine");
  } catch (const std::exception& e) {
    std::println(stderr, "tasks-line: {}", e.what());
  }
  return EXIT_FAILURE;
}
