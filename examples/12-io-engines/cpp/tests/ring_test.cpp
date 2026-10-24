#include "ring.hpp"

#include <gtest/gtest.h>

#include <cstring>

namespace lowlat::io {

TEST(Ring, QueueInitSucceedsOrSkipsWithTheReason) {
  const auto ring = probe_ring(8);
  if (!ring && (ring.error() == EPERM || ring.error() == ENOSYS)) {
    GTEST_SKIP() << "io_uring_queue_init failed with " << std::strerror(ring.error()) << " (errno "
                 << ring.error() << "): blocked by seccomp or absent from this kernel";
  }
  ASSERT_TRUE(ring.has_value()) << "io_uring_queue_init errno " << ring.error();
}

}  // namespace lowlat::io
