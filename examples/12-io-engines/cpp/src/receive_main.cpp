// io-receive: the Ch12 receive path in C++ (see ../README.md).
//
// Four tunnel cameras (four simulator instances, flat wire, one UDP port each) feed a receiver.
// The variants differ in how a datagram wakes a thread, and in how many threads there are:
//
//   epoll            one thread, four sockets: epoll_wait + recvmsg           (readiness)
//   recvmmsg         one thread, four sockets: epoll_wait + recvmmsg batch    (readiness, batched)
//   io-uring         one thread, four sockets: multishot recvmsg, buffer ring (completion)
//   thread-per-core  four threads, each its own socket and its own ring      (shared nothing)
//   acceptor-pool    one io-uring thread + hand-off to four decide workers    (hand-off)
//
//   io-receive --variant NAME [--bind 127.0.0.1] [--base-port 47320] [--expect 50000] [--cpus A,B,C,D,E] [--hold-ms N]
//              [--idle-ms 1500] [--receive-ns 0] [--decide-ns 0] [--report FILE]
//   io-receive --probe-uring       exit 0 when io_uring works here, 77 (skip) on EPERM / ENOSYS
//
// Provenance: the raw epoll loop and the pinned-thread start protocol follow the companion project
// cpp-concurrency-and-parallelism, 12-asio-strand (raw epoll beside io_context); the hand-off pool
// is Ch10's multi-producer log.
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <format>
#include <memory>
#include <optional>
#include <print>
#include <span>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "lowlat/io/engines.hpp"
#include "lowlat/io/handoff.hpp"
#include "lowlat/io/sockets.hpp"
#include "lowlat/io/work.hpp"
#include "lowlat/line/signals.hpp"
#include "lowlat/lockfree/options.hpp"
#include "lowlat/lockfree/placement.hpp"
#include "lowlat/lockfree/report_util.hpp"
#include "lowlat/measure/recorder.hpp"
#include "lowlat/measure/runtime.hpp"

namespace {

namespace io = lowlat::io;
namespace lf = lowlat::lockfree;
namespace line = lowlat::line;
namespace measure = lowlat::measure;

constexpr std::string_view kExample = "12-io-engines";
constexpr int kSkipCode = 77;  // the automake "skipped" status, as lib.sh strace_summary uses

enum class Engine { epoll, recvmmsg, uring };

struct Plan {
  std::string variant;
  Engine engine;
  std::size_t receivers;  ///< receive threads
  std::size_t workers;    ///< decide workers behind a hand-off (0: the receive thread decides)
  [[nodiscard]] std::size_t threads() const noexcept { return receivers + workers; }
};

Plan plan_for(const std::string& variant) {
  if (variant == "epoll") return {variant, Engine::epoll, 1, 0};
  if (variant == "recvmmsg") return {variant, Engine::recvmmsg, 1, 0};
  if (variant == "io-uring") return {variant, Engine::uring, 1, 0};
  if (variant == "thread-per-core") return {variant, Engine::uring, io::kCameras, 0};
  if (variant == "acceptor-pool") return {variant, Engine::uring, 1, io::kCameras};
  throw std::invalid_argument("--variant: epoll | recvmmsg | io-uring | thread-per-core | acceptor-pool");
}

/// io_uring_queue_init on a throwaway ring: the errno, or 0.
int uring_probe() {
  auto ring = io::Ring::create(8);
  return ring ? 0 : ring.error();
}

struct Shared {
  std::vector<io::EngineCounters> counters;    // one per thread, padded
  std::vector<measure::Recorder> recorders;    // one per thread
  std::vector<std::uint64_t> lost;             // per receiver
  std::vector<int> rcvbuf;                     // per receiver: what the kernel granted
  std::vector<std::string> failures;           // per thread
};

int run(const lf::Options& o) {
  const Plan plan = plan_for(o.text("variant", ""));
  const auto base_port = static_cast<std::uint16_t>(o.number("base-port", 47320));
  const std::uint64_t expect = o.number("expect", 50'000);
  const std::string bind_address = o.text("bind", "127.0.0.1");  // Ch13's bridge lane passes 0.0.0.0
  const int idle_ms = static_cast<int>(o.number("idle-ms", 1500));
  const std::string report_path = o.text("report", "");
  const auto work_ns = static_cast<std::int64_t>(o.number("decide-ns", 0));
  // Modelled receive-side work per datagram, done by whichever thread received it: the validation a real camera frame
  // carries (a checksum, a framing check) that this wire does not. A single acceptor does it for every camera.
  const auto receive_ns = static_cast<std::int64_t>(o.number("receive-ns", 0));
  std::vector<int> cpus(plan.threads(), -1);
  if (const std::string list = o.text("cpus", ""); !list.empty()) {
    cpus = lf::parse_cpu_list(list);
    if (cpus.size() < plan.threads()) {
      throw std::invalid_argument(std::format("--cpus needs {} CPUs for {}", plan.threads(), plan.variant));
    }
    cpus.resize(plan.threads());
  }
  if (plan.engine == Engine::uring) {
    if (const int err = uring_probe(); err != 0) {
      std::println("io-receive: io_uring unavailable here (errno {}: {}); skipped", err, std::strerror(err));
      return kSkipCode;
    }
  }
  if (!report_path.empty()) (void)measure::load_profile();

  line::install_stop_handlers();
  lf::Gate gate{static_cast<std::ptrdiff_t>(plan.threads()), std::chrono::milliseconds{o.number("hold-ms", 0)}};
  Shared shared;
  shared.counters.resize(plan.threads());
  shared.recorders.reserve(plan.threads());
  for (std::size_t t = 0; t < plan.threads(); ++t) shared.recorders.emplace_back(std::string{kExample}, plan.variant);
  shared.lost.assign(plan.receivers, 0);
  shared.rcvbuf.assign(plan.receivers, 0);
  shared.failures.assign(plan.threads(), "");
  std::optional<io::HandoffPool> pool;
  if (plan.workers > 0) pool.emplace(plan.workers);
  io::SpinStart spin{static_cast<int>(plan.threads())};
  const io::LoopConfig loop{&line::g_stop, idle_ms, 100};

  // Receiver r owns cameras [first, first + count): every camera for the single-thread variants,
  // one each for thread-per-core.
  const std::size_t per_receiver = io::kCameras / plan.receivers;
  auto receiver = [&](std::size_t r) {
    io::EngineCounters& counters = shared.counters[r];
    measure::Recorder& recorder = shared.recorders[r];
    std::vector<line::Fd> fds;
    std::vector<io::Camera> cameras;
    std::unique_ptr<io::UringReceiver> uring;
    bool ready = false;
    try {
      for (std::size_t c = r * per_receiver; c < (r + 1) * per_receiver; ++c) {
        io::Bound b = io::open_udp(static_cast<std::uint16_t>(base_port + c), 4 * 1024 * 1024, bind_address);
        shared.rcvbuf[r] = b.rcvbuf_granted;
        cameras.push_back({b.fd.get(), expect, line::SeqTracker{}});
        fds.push_back(std::move(b.fd));
      }
      if (plan.engine == Engine::uring) {
        auto made = io::UringReceiver::create(cameras);
        if (!made) throw std::runtime_error(std::format("io_uring setup failed, errno {}", made.error()));
        uring = std::move(*made);
      }
      ready = true;
    } catch (const std::exception& e) {
      shared.failures[r] = e.what();
    }
    gate.worker_ready(cpus[r], plan.workers > 0 ? "acceptor" : std::format("receiver-{}", r));
    counters.start_ns = spin.arrive_and_go();
    if (!ready) {
      if (pool) pool->finish();  // the workers wait for the end marker even when this thread could not start
      return;
    }
    try {
      auto handle = [&](std::size_t camera, std::span<const std::byte> bytes) {
        const std::int64_t now = line::monotonic_ns();
        if (counters.first_rx_ns == 0) {
          counters.first_rx_ns = now;
          counters.cpu_first_ns = io::thread_cpu_ns();
        }
        counters.last_rx_ns = now;
        io::spin_work(receive_ns);
        if (const auto parcel = io::accept(cameras[camera], bytes, counters)) {
          if (pool) {
            pool->send(*parcel, counters);
          } else {
            io::decide(*parcel, counters, recorder, work_ns);
          }
        }
      };
      switch (plan.engine) {
        case Engine::epoll: io::run_epoll(cameras, handle, counters, loop); break;
        case Engine::recvmmsg: io::run_recvmmsg(cameras, handle, counters, loop); break;
        case Engine::uring: uring->run(handle, counters, loop); break;
      }
    } catch (const std::exception& e) {
      shared.failures[r] = e.what();
    }
    counters.cpu_last_ns = io::thread_cpu_ns();
    for (const io::Camera& c : cameras) shared.lost[r] += c.lost();
    if (pool) pool->finish();
  };

  auto worker = [&](std::size_t w) {
    const std::size_t t = plan.receivers + w;
    gate.worker_ready(cpus[t], std::format("worker-{}", w));
    shared.counters[t].start_ns = spin.arrive_and_go();
    try {
      pool->work(w, shared.counters[t], shared.recorders[t], work_ns);
    } catch (const std::exception& e) {
      shared.failures[t] = e.what();
    }
  };

  {
    std::vector<std::jthread> threads;
    threads.reserve(plan.threads());
    for (std::size_t r = 0; r < plan.receivers; ++r) threads.emplace_back(receiver, r);
    for (std::size_t w = 0; w < plan.workers; ++w) threads.emplace_back(worker, w);
    gate.release();
  }  // jthreads join

  for (std::size_t t = 0; t < plan.threads(); ++t) {
    if (!shared.failures[t].empty()) {
      std::println(stderr, "io-receive: thread {} failed: {}", t, shared.failures[t]);
      return EXIT_FAILURE;
    }
  }

  io::EngineCounters total;
  std::int64_t first_start = shared.counters[0].start_ns, last_start = first_start;
  for (const io::EngineCounters& c : shared.counters) {
    total += c;
    first_start = std::min(first_start, c.start_ns);
    last_start = std::max(last_start, c.start_ns);
  }
  std::uint64_t dropped = 0;
  for (const std::uint64_t l : shared.lost) dropped += l;
  measure::Recorder merged{std::string{kExample}, plan.variant};
  for (const measure::Recorder& r : shared.recorders) lf::merge_into(merged, r);
  merged.add_dropped(dropped);

  const std::int64_t skew_ns = last_start - first_start;
  std::int64_t busiest = 0;  // the most loaded receive thread: the acceptor, or the busiest of the four receivers
  for (std::size_t r = 0; r < plan.receivers; ++r) busiest = std::max(busiest, io::busy_permille(shared.counters[r]));
  const std::uint64_t syscalls = total.syscalls();
  std::println("receive: {} parcels {} dropped {} syscalls {} (epoll_wait {} recvmsg {} recvmmsg {} io_uring_enter {}) cqes {} handoffs {} start skew {} ns",
               plan.variant, total.parcels, dropped, syscalls, total.epoll_waits, total.recvmsgs, total.recvmmsgs,
               total.enters, total.cqes, total.handoffs, skew_ns);
  merged.print_summary();
  if (report_path.empty()) return 0;

  nlohmann::json runtime;
  if (std::ranges::all_of(cpus, [](int c) { return c >= 0; })) runtime["placement"] = lf::placement_of(cpus);
  const auto count = [](std::uint64_t v) { return static_cast<std::int64_t>(v); };
  runtime["counters"] = measure::counters({{"parcels", count(total.parcels)},
                                           {"datagrams", count(total.datagrams)},
                                           {"malformed", count(total.malformed)},
                                           {"dropped", count(dropped)},
                                           {"syscalls", count(syscalls)},
                                           {"epoll_wait_calls", count(total.epoll_waits)},
                                           {"recvmsg_calls", count(total.recvmsgs)},
                                           {"recvmmsg_calls", count(total.recvmmsgs)},
                                           {"io_uring_enter_calls", count(total.enters)},
                                           {"cqes", count(total.cqes)},
                                           {"multishot_rearms", count(total.rearms)},
                                           {"handoffs", count(total.handoffs)},
                                           {"start_skew_ns", skew_ns},
                                           {"receiver_busy_permille_max", busiest},
                                           {"io_uring_setup_errno", 0},
                                           {"rcvbuf_granted", shared.rcvbuf[0]},
                                           {"threads", count(plan.threads())}});
  const std::string notes = std::format(
      "receive; cameras={}; expect_per_camera={}; flat wire; engine={}; receivers={}; workers={}; idle_ms={}; receive_ns={}; decide_ns={}",
      io::kCameras, expect, plan.engine == Engine::epoll ? "epoll" : plan.engine == Engine::recvmmsg ? "recvmmsg" : "io_uring",
      plan.receivers, plan.workers, idle_ms, receive_ns, work_ns);
  merged.write_report(std::filesystem::path{report_path}, notes, std::nullopt, runtime);
  std::println("report: {}", report_path);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const lf::Options o{argc, argv, 1, {"probe-uring"}};
    if (o.flag("probe-uring")) {
      const int err = uring_probe();
      std::println("io_uring_setup errno {}{}", err, err == 0 ? "" : std::format(" ({})", std::strerror(err)));
      return err == 0 ? EXIT_SUCCESS : (err == EPERM || err == ENOSYS) ? kSkipCode : EXIT_FAILURE;
    }
    return run(o);
  } catch (const std::exception& e) {
    std::println(stderr, "io-receive: {}", e.what());
    return EXIT_FAILURE;
  }
}
