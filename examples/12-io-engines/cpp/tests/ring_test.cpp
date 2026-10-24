#include "ring.hpp"

#include <gtest/gtest.h>

#include <cerrno>
#include <cstring>
#include <utility>

namespace lowlat::io {

TEST(Ring, QueueInitSucceedsOrSkipsWithTheReason) {
  auto ring = Ring::create(8);
  if (!ring && (ring.error() == EPERM || ring.error() == ENOSYS)) {
    GTEST_SKIP() << "io_uring_queue_init failed with " << std::strerror(ring.error()) << " (errno "
                 << ring.error() << "): blocked by seccomp or absent from this kernel";
  }
  ASSERT_TRUE(ring.has_value()) << "io_uring_queue_init errno " << ring.error();
  EXPECT_TRUE(ring->live());

  Ring moved = std::move(*ring);  // ownership moves; the source no longer exits the ring
  EXPECT_TRUE(moved.live());
  EXPECT_FALSE(ring->live());
}

}  // namespace lowlat::io
