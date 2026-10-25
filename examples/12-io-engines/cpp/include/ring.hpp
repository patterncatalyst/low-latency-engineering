// Ch12: owning wrappers over liburing, one for the ring and one for a provided-buffer ring.
#pragma once

#include <liburing.h>

#include <cstddef>
#include <cstdint>
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

/// A provided-buffer ring registered with a Ring: the kernel picks a free buffer for each
/// completion and reports its id, so no buffer is committed to a receive in advance. Frees the
/// registration on destruction; the Ring it was made on must outlive it and must not move.
class BufRing {
 public:
  /// `entries` must be a power of two. The error is the errno from io_uring_setup_buf_ring.
  static std::expected<BufRing, int> create(Ring& ring, unsigned entries, unsigned group) {
    int err = 0;
    io_uring_buf_ring* br = io_uring_setup_buf_ring(ring.get(), entries, static_cast<int>(group), 0, &err);
    if (br == nullptr) return std::unexpected(-err);
    return BufRing{ring.get(), br, entries, group};
  }

  BufRing(const BufRing&) = delete;
  BufRing& operator=(const BufRing&) = delete;
  BufRing(BufRing&& o) noexcept
      : ring_(o.ring_), br_(std::exchange(o.br_, nullptr)), entries_(o.entries_), group_(o.group_) {}
  BufRing& operator=(BufRing&& o) noexcept {
    if (this != &o) {
      reset();
      ring_ = o.ring_;
      br_ = std::exchange(o.br_, nullptr);
      entries_ = o.entries_;
      group_ = o.group_;
    }
    return *this;
  }
  ~BufRing() { reset(); }

  /// Offers buffer `id` (address `addr`, `len` bytes) at position `offset` past the current tail.
  /// Publish a batch with advance().
  void add(void* addr, unsigned len, unsigned short id, int offset) noexcept {
    io_uring_buf_ring_add(br_, addr, len, id, io_uring_buf_ring_mask(entries_), offset);
  }
  void advance(int count) noexcept { io_uring_buf_ring_advance(br_, count); }
  [[nodiscard]] unsigned group() const noexcept { return group_; }
  [[nodiscard]] unsigned entries() const noexcept { return entries_; }

 private:
  BufRing(io_uring* ring, io_uring_buf_ring* br, unsigned entries, unsigned group)
      : ring_(ring), br_(br), entries_(entries), group_(group) {}
  void reset() noexcept {
    if (br_ != nullptr) {
      io_uring_free_buf_ring(ring_, br_, entries_, static_cast<int>(group_));
      br_ = nullptr;
    }
  }

  io_uring* ring_;
  io_uring_buf_ring* br_;
  unsigned entries_;
  unsigned group_;
};

}  // namespace lowlat::io
