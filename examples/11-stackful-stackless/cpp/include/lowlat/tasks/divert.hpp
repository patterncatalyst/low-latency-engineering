// The command path of the line run (adapted from example 10): divert commands leave the deciding tasks
// on their own UDP socket, to the diverter's own address. It shares nothing with the data path (the
// scan socket and the hand-off to the tasks), so a flood of scans cannot queue ahead of a command and
// a slow command listener cannot back up the scans.
#pragma once

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <array>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <utility>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/line/fd.hpp"
#include "lowlat/line/v1/divert.pb.h"
#include "lowlat/measure/recorder.hpp"

namespace lowlat::tasks {

/// The actuator end: a thread that blocks on the command socket, counts the commands and records how
/// long each took from the tracker's decision to its arrival. It blocks in the kernel and never
/// spins, so it is not one of the pinned threads.
class DivertListener {
 public:
  DivertListener(std::string example, std::string variant)
      : bound_{line::open_bound("127.0.0.1:0", 4 << 20, 50)},
        port_{line::bound_port_of(bound_.fd.get())},
        latency_{std::move(example), std::move(variant)},
        thread_{[this](const std::stop_token& stop) { listen(stop); }} {}

  /// Where the tracker sends its commands.
  [[nodiscard]] int port() const noexcept { return port_; }
  [[nodiscard]] std::uint64_t received() const noexcept { return received_.load(std::memory_order_acquire); }

  /// Stops and joins the listener; its recorder is safe to read afterwards.
  [[nodiscard]] measure::Recorder& stop_and_take() {
    thread_.request_stop();
    thread_.join();
    return latency_;
  }

 private:
  void listen(const std::stop_token& stop) {
    std::array<char, 128> datagram{};
    while (!stop.stop_requested()) {
      const ssize_t n = ::recv(bound_.fd.get(), datagram.data(), datagram.size(), 0);
      if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
        throw std::system_error(errno, std::generic_category(), "recv (command socket)");
      }
      const std::int64_t arrived_ns = line::monotonic_ns();
      line::v1::DivertCommand command;
      if (!command.ParseFromArray(datagram.data(), static_cast<int>(n))) throw std::runtime_error("not a DivertCommand");
      latency_.record(arrived_ns - command.decided_ns());
      received_.fetch_add(1, std::memory_order_release);
    }
  }

  line::Bound bound_;
  int port_;
  measure::Recorder latency_;
  std::atomic<std::uint64_t> received_{0};
  std::jthread thread_;  // last member: it starts in the constructor and uses everything above
};

/// The tracker's end: one connected UDP socket per sender.
class CommandSender {
 public:
  explicit CommandSender(int port) : fd_{::socket(AF_INET, SOCK_DGRAM, 0)} {
    if (fd_.get() < 0) throw std::system_error(errno, std::generic_category(), "socket");
    sockaddr_in to{};
    to.sin_family = AF_INET;
    to.sin_port = htons(static_cast<std::uint16_t>(port));
    ::inet_pton(AF_INET, "127.0.0.1", &to.sin_addr);
    if (::connect(fd_.get(), reinterpret_cast<const sockaddr*>(&to), sizeof to) != 0) {
      throw std::system_error(errno, std::generic_category(), "connect (command socket)");
    }
  }

  void send(const line::v1::DivertCommand& command) {
    std::array<char, 128> out{};
    if (!command.SerializeToArray(out.data(), static_cast<int>(out.size()))) throw std::runtime_error("command too large");
    if (::send(fd_.get(), out.data(), command.ByteSizeLong(), 0) < 0) {
      throw std::system_error(errno, std::generic_category(), "send (command socket)");
    }
  }

 private:
  line::Fd fd_;
};

}  // namespace lowlat::tasks
