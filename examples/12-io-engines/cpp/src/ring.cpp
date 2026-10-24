#include "ring.hpp"

namespace lowlat::io {

std::expected<Ring, int> Ring::create(unsigned entries, unsigned flags) {
  Ring ring;
  const int rc = io_uring_queue_init(entries, &ring.ring_, flags);
  if (rc < 0) {
    return std::unexpected(-rc);
  }
  ring.live_ = true;
  return ring;
}

}  // namespace lowlat::io
