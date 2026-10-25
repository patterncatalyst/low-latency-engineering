#include "lowlat/io/sockets.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <cerrno>
#include <stdexcept>
#include <string>
#include <system_error>

namespace lowlat::io {

namespace {

[[noreturn]] void fail(const char* what) { throw std::system_error(errno, std::generic_category(), what); }

}  // namespace

Bound open_udp(std::uint16_t port, int rcvbuf, std::string_view address) {
  line::Fd fd{::socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0)};
  if (fd.get() < 0) fail("socket");
  const int on = 1;
  if (::setsockopt(fd.get(), SOL_SOCKET, SO_REUSEPORT, &on, sizeof on) != 0) fail("setsockopt SO_REUSEPORT");
  if (::setsockopt(fd.get(), SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf) != 0) fail("setsockopt SO_RCVBUF");
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  const std::string text{address};
  if (::inet_pton(AF_INET, text.c_str(), &addr.sin_addr) != 1) throw std::invalid_argument("not an IPv4 address: " + text);
  if (::bind(fd.get(), reinterpret_cast<const sockaddr*>(&addr), sizeof addr) != 0) fail("bind");
  socklen_t len = sizeof addr;
  if (::getsockname(fd.get(), reinterpret_cast<sockaddr*>(&addr), &len) != 0) fail("getsockname");
  int granted = 0;
  socklen_t glen = sizeof granted;
  if (::getsockopt(fd.get(), SOL_SOCKET, SO_RCVBUF, &granted, &glen) != 0) fail("getsockopt SO_RCVBUF");
  return {std::move(fd), ntohs(addr.sin_port), granted};
}

}  // namespace lowlat::io
