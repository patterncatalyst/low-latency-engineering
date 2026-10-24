// Ch12 wiring skeleton: set up and tear down an io_uring ring.
#pragma once

#include <cerrno>
#include <expected>

namespace lowlat::io {

// 0 on success, otherwise the errno from io_uring_queue_init (EPERM under a seccomp profile that
// blocks io_uring, ENOSYS on a kernel without it).
std::expected<void, int> probe_ring(unsigned entries);

}  // namespace lowlat::io
