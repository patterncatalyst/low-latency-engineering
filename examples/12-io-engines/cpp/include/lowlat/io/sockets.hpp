// Non-blocking UDP sockets for the receive engines.
#pragma once

#include <cstdint>

#include "lowlat/line/fd.hpp"

namespace lowlat::io {

struct Bound {
  line::Fd fd;
  std::uint16_t port;
  int rcvbuf_granted;
};

/// A non-blocking IPv4 UDP socket bound to 127.0.0.1:`port` (0 picks one), SO_REUSEPORT set so that
/// a second socket can bind the same port, and SO_RCVBUF requested at `rcvbuf` bytes (Linux caps
/// the request at net.core.rmem_max and doubles what it grants). Throws std::system_error.
[[nodiscard]] Bound open_udp(std::uint16_t port, int rcvbuf = 4 * 1024 * 1024);

}  // namespace lowlat::io
