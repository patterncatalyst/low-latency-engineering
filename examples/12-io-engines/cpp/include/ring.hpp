// Ch12 wiring skeleton: an owning io_uring ring.
#pragma once

#include <liburing.h>

#include <expected>
#include <utility>

namespace lowlat::io {

// Owns one initialised io_uring. Move-only; the destructor calls io_uring_queue_exit.
class Ring {
 public:
  // The ring, or the errno from io_uring_queue_init (EPERM under a seccomp profile that blocks
  // io_uring, ENOSYS on a kernel without it).
  static std::expected<Ring, int> create(unsigned entries, unsigned flags = 0);

  Ring(const Ring&) = delete;
  Ring& operator=(const Ring&) = delete;
  Ring(Ring&& other) noexcept : ring_(other.ring_), live_(std::exchange(other.live_, false)) {}
  Ring& operator=(Ring&& other) noexcept {
    if (this != &other) {
      reset();
      ring_ = other.ring_;
      live_ = std::exchange(other.live_, false);
    }
    return *this;
  }
  ~Ring() { reset(); }

  io_uring* get() noexcept { return &ring_; }
  [[nodiscard]] bool live() const noexcept { return live_; }

 private:
  Ring() = default;
  void reset() noexcept {
    if (live_) {
      io_uring_queue_exit(&ring_);
      live_ = false;
    }
  }

  io_uring ring_{};
  bool live_ = false;
};

}  // namespace lowlat::io
