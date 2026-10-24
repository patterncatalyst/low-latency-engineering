// io-receive-asio: the same receive path through Boost.Asio built on its io_uring backend.
//
//   io-receive-asio [--base-port 47320] [--expect 50000] [--cpus A] [--hold-ms N] [--idle-ms 1500] [--report FILE]
//
// Observed, not asserted. Asio hides the engine behind io_context::run(): the handler below is the
// whole program. This target is compiled with BOOST_ASIO_HAS_IO_URING and BOOST_ASIO_DISABLE_EPOLL
// (see CMakeLists.txt): with the first alone Asio uses io_uring for files and keeps epoll for sockets;
// with both, sockets are served by io_uring too. Asio keeps its own ring, so this program cannot count
// the calls; the strace cross-check does.
//
// Provenance: io_context, work guard and handler structure follow the companion project
// cpp-concurrency-and-parallelism, 12-asio-strand (raw epoll beside io_context).
#include <boost/asio.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <format>
#include <memory>
#include <print>
#include <sys/socket.h>
#include <thread>
#include <span>
#include <string>
#include <vector>

#include "lowlat/io/engines.hpp"
#include "lowlat/io/work.hpp"
#include "lowlat/line/signals.hpp"
#include "lowlat/lockfree/options.hpp"
#include "lowlat/lockfree/placement.hpp"
#include "lowlat/measure/recorder.hpp"
#include "lowlat/measure/runtime.hpp"

namespace {

namespace asio = boost::asio;
namespace io = lowlat::io;
namespace lf = lowlat::lockfree;
namespace line = lowlat::line;
namespace measure = lowlat::measure;
using asio::ip::udp;

constexpr std::string_view kExample = "12-io-engines";
constexpr std::string_view kVariant = "asio-io-uring";

struct CameraSocket {
  explicit CameraSocket(asio::io_context& io, std::uint16_t port, std::uint64_t expect) : socket{io} {
    socket.open(udp::v4());
    socket.set_option(asio::socket_base::reuse_address{true});
    int on = 1;
    ::setsockopt(socket.native_handle(), SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
    socket.set_option(asio::socket_base::receive_buffer_size{4 * 1024 * 1024});
    socket.bind(udp::endpoint{asio::ip::address_v4::loopback(), port});
    state.expect = expect;
  }
  udp::socket socket;
  udp::endpoint from;
  alignas(8) std::array<std::byte, io::kDatagramBytes> buffer{};
  io::Camera state;
};

int run(const lf::Options& o) {
  const auto base_port = static_cast<std::uint16_t>(o.number("base-port", 47320));
  const std::uint64_t expect = o.number("expect", 50'000);
  const int idle_ms = static_cast<int>(o.number("idle-ms", 1500));
  const std::string report_path = o.text("report", "");
  const auto work_ns = static_cast<std::int64_t>(o.number("decide-ns", 0));
  std::vector<int> cpus{-1};
  if (const std::string list = o.text("cpus", ""); !list.empty()) cpus = {lf::parse_cpu_list(list).front()};
  if (!report_path.empty()) (void)measure::load_profile();
  line::install_stop_handlers();

  asio::io_context io{1};
  std::vector<std::unique_ptr<CameraSocket>> cameras;
  for (std::size_t c = 0; c < io::kCameras; ++c) {
    cameras.push_back(std::make_unique<CameraSocket>(io, static_cast<std::uint16_t>(base_port + c), expect));
  }

  io::EngineCounters counters;
  measure::Recorder recorder{std::string{kExample}, std::string{kVariant}};
  io::detail::Idle idle{io::LoopConfig{nullptr, idle_ms, 100}};
  const auto all_done = [&] {
    return std::ranges::all_of(cameras, [](const auto& c) { return c->state.complete(); });
  };

  // One receive per socket, re-armed from its own handler.
  auto receive = [&](auto&& self, CameraSocket& cam) -> void {
    cam.socket.async_receive_from(asio::buffer(cam.buffer), cam.from, [&, self](boost::system::error_code ec, std::size_t n) {
      if (ec == asio::error::operation_aborted) return;
      if (ec) throw boost::system::system_error{ec};
      idle.received();
      if (const auto parcel = io::accept(cam.state, std::span<const std::byte>{cam.buffer.data(), n}, counters)) {
        io::decide(*parcel, counters, recorder, work_ns);
      }
      if (all_done()) {
        io.stop();
        return;
      }
      self(self, cam);
    });
  };

  asio::steady_timer tick{io};
  auto watch = [&](auto&& self) -> void {
    tick.expires_after(std::chrono::milliseconds{100});
    tick.async_wait([&, self](boost::system::error_code ec) {
      if (ec) return;
      if (line::g_stop.load(std::memory_order_relaxed) || idle.expired()) {
        io.stop();
        return;
      }
      self(self);
    });
  };

  lf::Gate gate{1, std::chrono::milliseconds{o.number("hold-ms", 0)}};
  std::string failure;
  {
    std::jthread thread{[&] {
      gate.worker_ready(cpus[0], "asio-io-context");
      counters.start_ns = line::monotonic_ns();
      try {
        for (auto& cam : cameras) receive(receive, *cam);
        watch(watch);
        io.run();
      } catch (const std::exception& e) {
        failure = e.what();
      }
    }};
    gate.release();
  }
  if (!failure.empty()) {
    std::println(stderr, "io-receive-asio: {}", failure);
    return EXIT_FAILURE;
  }

  std::uint64_t dropped = 0;
  for (const auto& c : cameras) dropped += c->state.lost();
  recorder.add_dropped(dropped);
  std::println("receive: {} parcels {} dropped {} (system calls: see the strace summary)", kVariant, counters.parcels, dropped);
  recorder.print_summary();
  if (report_path.empty()) return 0;

  nlohmann::json runtime;
  if (cpus[0] >= 0) runtime["placement"] = lf::placement_of(cpus);
  const auto count = [](std::uint64_t v) { return static_cast<std::int64_t>(v); };
  runtime["counters"] = measure::counters({{"parcels", count(counters.parcels)},
                                           {"datagrams", count(counters.datagrams)},
                                           {"malformed", count(counters.malformed)},
                                           {"dropped", count(dropped)},
                                           {"start_skew_ns", 0},
                                           {"threads", 1}});
  recorder.write_report(std::filesystem::path{report_path},
                        std::format("receive; cameras={}; expect_per_camera={}; flat wire; engine=asio io_uring "
                                    "(BOOST_ASIO_HAS_IO_URING, BOOST_ASIO_DISABLE_EPOLL); receivers=1; workers=0; idle_ms={}; decide_ns={}",
                                    io::kCameras, expect, idle_ms, work_ns),
                        std::nullopt, runtime);
  std::println("report: {}", report_path);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return run(lf::Options{argc, argv, 1});
  } catch (const std::exception& e) {
    std::println(stderr, "io-receive-asio: {}", e.what());
    return EXIT_FAILURE;
  }
}
