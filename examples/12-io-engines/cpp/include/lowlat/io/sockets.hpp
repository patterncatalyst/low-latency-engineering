// Non-blocking UDP sockets for the receive engines.
#pragma once

#include <cstdint>
#include <string_view>

#include "lowlat/line/fd.hpp"

namespace lowlat::io {

struct Bound {
  line::Fd fd;
  std::uint16_t port;
  int rcvbuf_granted;
};

/// A non-blocking IPv4 UDP socket bound to `address`:`port` (`address` defaults to 127.0.0.1; Ch13's bridge lane passes
/// 0.0.0.0 so that datagrams arriving on the container's bridge address reach it; 0 picks a port), SO_REUSEPORT set so that
/// a second socket can bind the same port, and SO_RCVBUF requested at `rcvbuf` bytes (Linux caps
/// the request at net.core.rmem_max and doubles what it grants). Throws std::system_error, and std::invalid_argument
/// when `address` is not a dotted IPv4 address.
[[nodiscard]] Bound open_udp(std::uint16_t port, int rcvbuf = 4 * 1024 * 1024, std::string_view address = "127.0.0.1");

}  // namespace lowlat::io
