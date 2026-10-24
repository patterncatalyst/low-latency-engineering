#include "ring.hpp"

#include <liburing.h>

namespace lowlat::io {

std::expected<void, int> probe_ring(unsigned entries) {
  io_uring ring{};
  const int rc = io_uring_queue_init(entries, &ring, 0);
  if (rc < 0) {
    return std::unexpected(-rc);
  }
  io_uring_queue_exit(&ring);
  return {};
}

}  // namespace lowlat::io
