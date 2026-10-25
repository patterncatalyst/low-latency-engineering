// The receive engines. Each one gets datagrams from a set of non-blocking UDP sockets and calls
// `handle(camera_index, bytes)` for every datagram; what happens next is the caller's. Each counts
// every system call it makes in the thread's EngineCounters, so the number is exact and does not
// depend on a tracer.
//
//   epoll      readiness: epoll_wait says which socket has data, recvmsg takes one datagram from it.
//              This is the loop Asio's reactor runs underneath; it is written out here once so the
//              system calls are visible. Asio (io_context, async_receive_from) is the idiom.
//   recvmmsg   readiness plus a batch: after epoll_wait, one recvmmsg takes up to kBatch datagrams.
//   io-uring   completion: a multishot recvmsg per socket, buffers chosen by the kernel from a
//              provided-buffer ring. One io_uring_enter waits for completions; the completions that
//              are already queued are reaped with no system call at all.
#pragma once

#include <netinet/in.h>
#include <sys/epoll.h>
#include <sys/socket.h>

#include <array>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <memory>
#include <optional>
#include <span>
#include <system_error>
#include <vector>

#include "lowlat/io/work.hpp"
#include "lowlat/line/clock.hpp"
#include "lowlat/line/fd.hpp"
#include "ring.hpp"

namespace lowlat::io {

struct LoopConfig {
  const std::atomic<bool>* stop = nullptr;  ///< set from a signal handler; may be null
  int idle_ms = 1500;                       ///< stop this long after the last datagram
  int tick_ms = 100;                        ///< longest a wait blocks before the loop looks at stop and idle
};

namespace detail {

class Idle {
 public:
  explicit Idle(const LoopConfig& cfg) : idle_ns_(std::int64_t{cfg.idle_ms} * 1'000'000) {}
  void received() noexcept {
    started_ = true;
    last_ns_ = line::monotonic_ns();
  }
  /// True once something arrived and then nothing did for idle_ms.
  [[nodiscard]] bool expired() const noexcept { return started_ && line::monotonic_ns() - last_ns_ >= idle_ns_; }

 private:
  std::int64_t idle_ns_;
  std::int64_t last_ns_ = 0;
  bool started_ = false;
};

[[nodiscard]] inline bool stopped(const LoopConfig& cfg) noexcept {
  return cfg.stop != nullptr && cfg.stop->load(std::memory_order_relaxed);
}

[[noreturn]] inline void fail(int err, const char* what) { throw std::system_error(err, std::generic_category(), what); }

[[nodiscard]] inline line::Fd make_epoll(std::span<const Camera> cameras) {
  line::Fd ep{::epoll_create1(EPOLL_CLOEXEC)};
  if (ep.get() < 0) fail(errno, "epoll_create1");
  for (std::size_t i = 0; i < cameras.size(); ++i) {
    epoll_event ev{};
    ev.events = EPOLLIN;
    ev.data.u32 = static_cast<std::uint32_t>(i);
    if (::epoll_ctl(ep.get(), EPOLL_CTL_ADD, cameras[i].fd, &ev) != 0) fail(errno, "epoll_ctl");
  }
  return ep;
}

}  // namespace detail

inline constexpr std::size_t kBatch = 32;
inline constexpr std::size_t kDatagramBytes = 128;  // a parcel-v1 record is 80; room to see a longer one

/// Readiness, one datagram per wake-up per ready socket: epoll_wait, then recvmsg.
template <class Handler>
void run_epoll(std::span<Camera> cameras, Handler&& handle, EngineCounters& counters, const LoopConfig& cfg) {
  const line::Fd ep = detail::make_epoll(cameras);
  detail::Idle idle{cfg};
  std::array<epoll_event, 16> events{};
  alignas(8) std::array<std::byte, kDatagramBytes> buffer{};
  while (!detail::stopped(cfg) && !all_complete(cameras)) {
    const int n = ::epoll_wait(ep.get(), events.data(), static_cast<int>(events.size()), cfg.tick_ms);
    ++counters.epoll_waits;
    if (n < 0) {
      if (errno == EINTR) continue;
      detail::fail(errno, "epoll_wait");
    }
    if (n == 0) {
      if (idle.expired()) return;
      continue;
    }
    for (int e = 0; e < n; ++e) {
      const std::uint32_t index = events[static_cast<std::size_t>(e)].data.u32;
      iovec iov{buffer.data(), buffer.size()};
      msghdr msg{};
      msg.msg_iov = &iov;
      msg.msg_iovlen = 1;
      const ssize_t got = ::recvmsg(cameras[index].fd, &msg, MSG_DONTWAIT);
      ++counters.recvmsgs;
      if (got < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
        detail::fail(errno, "recvmsg");
      }
      idle.received();
      handle(index, std::span<const std::byte>{buffer.data(), static_cast<std::size_t>(got)});
    }
  }
}

/// Readiness and a batch: epoll_wait, then one recvmmsg per ready socket takes what is queued, up to kBatch.
template <class Handler>
void run_recvmmsg(std::span<Camera> cameras, Handler&& handle, EngineCounters& counters, const LoopConfig& cfg) {
  const line::Fd ep = detail::make_epoll(cameras);
  detail::Idle idle{cfg};
  std::array<epoll_event, 16> events{};
  alignas(8) std::array<std::array<std::byte, kDatagramBytes>, kBatch> buffers{};
  std::array<iovec, kBatch> iov{};
  std::array<mmsghdr, kBatch> msgs{};
  for (std::size_t i = 0; i < kBatch; ++i) {
    iov[i] = {buffers[i].data(), buffers[i].size()};
    msgs[i].msg_hdr.msg_iov = &iov[i];
    msgs[i].msg_hdr.msg_iovlen = 1;
  }
  while (!detail::stopped(cfg) && !all_complete(cameras)) {
    const int n = ::epoll_wait(ep.get(), events.data(), static_cast<int>(events.size()), cfg.tick_ms);
    ++counters.epoll_waits;
    if (n < 0) {
      if (errno == EINTR) continue;
      detail::fail(errno, "epoll_wait");
    }
    if (n == 0) {
      if (idle.expired()) return;
      continue;
    }
    for (int e = 0; e < n; ++e) {
      const std::uint32_t index = events[static_cast<std::size_t>(e)].data.u32;
      const int got = ::recvmmsg(cameras[index].fd, msgs.data(), static_cast<unsigned>(kBatch), MSG_DONTWAIT, nullptr);
      ++counters.recvmmsgs;
      if (got < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
        detail::fail(errno, "recvmmsg");
      }
      idle.received();
      for (int k = 0; k < got; ++k) {
        handle(index, std::span<const std::byte>{buffers[static_cast<std::size_t>(k)].data(), msgs[static_cast<std::size_t>(k)].msg_len});
      }
    }
  }
}

/// Completion: multishot recvmsg on every socket, buffers from one provided-buffer ring. Create it
/// (which sets the ring up and can fail with EPERM or ENOSYS) before the start gate, then run().
class UringReceiver {
 public:
  static constexpr unsigned kBufferGroup = 1;
  static constexpr std::size_t kBufferBytes = 256;  // io_uring_recvmsg_out + sockaddr_in + the datagram

  /// The receiver, or the errno from io_uring_queue_init / io_uring_setup_buf_ring. `buffers` is a power of two.
  static std::expected<std::unique_ptr<UringReceiver>, int> create(std::span<Camera> cameras, unsigned entries = 256,
                                                                   unsigned buffers = 1024) {
    auto ring = Ring::create(entries);
    if (!ring) return std::unexpected(ring.error());
    // A private constructor plus `new`: std::make_unique can't reach a private constructor, and the receiver must not
    // move once the BufRing is registered on its ring_ (the kernel and the BufRing hold addresses inside it).
    std::unique_ptr<UringReceiver> self{new UringReceiver(std::move(*ring), cameras, buffers)};
    auto bufs = BufRing::create(self->ring_, buffers, kBufferGroup);
    if (!bufs) return std::unexpected(bufs.error());
    self->bufs_.emplace(std::move(*bufs));
    for (unsigned id = 0; id < buffers; ++id) {
      self->bufs_->add(self->arena_.data() + std::size_t{id} * kBufferBytes, static_cast<unsigned>(kBufferBytes),
                       static_cast<unsigned short>(id), static_cast<int>(id));
    }
    self->bufs_->advance(static_cast<int>(buffers));
    return self;
  }

  UringReceiver(const UringReceiver&) = delete;
  UringReceiver& operator=(const UringReceiver&) = delete;

  template <class Handler>
  void run(Handler&& handle, EngineCounters& counters, const LoopConfig& cfg) {
    detail::Idle idle{cfg};
    for (std::size_t i = 0; i < cameras_.size(); ++i) arm(i);
    const __kernel_timespec tick{.tv_sec = cfg.tick_ms / 1000, .tv_nsec = std::int64_t{cfg.tick_ms % 1000} * 1'000'000};
    while (!detail::stopped(cfg) && !all_complete(cameras_)) {
      unsigned head = 0;
      unsigned reaped = 0;
      io_uring_cqe* cqe = nullptr;
      io_uring_for_each_cqe(ring_.get(), head, cqe) {
        reap(*cqe, handle, counters, idle);
        ++reaped;
      }
      if (reaped > 0) {
        io_uring_cq_advance(ring_.get(), reaped);
        bufs_->advance(static_cast<int>(returned_));
        returned_ = 0;
        counters.cqes += reaped;
        continue;  // completions may have arrived while these were handled: look before sleeping
      }
      // Nothing queued: one io_uring_enter submits any re-armed receive and waits for a completion.
      io_uring_cqe* first = nullptr;
      const int rc = io_uring_submit_and_wait_timeout(ring_.get(), &first, 1, const_cast<__kernel_timespec*>(&tick), nullptr);
      ++counters.enters;
      if (rc == -ETIME || rc == -EINTR || rc == -EAGAIN) {
        if (idle.expired()) return;
        continue;
      }
      if (rc < 0) detail::fail(-rc, "io_uring_submit_and_wait_timeout");
    }
  }

 private:
  UringReceiver(Ring ring, std::span<Camera> cameras, unsigned buffers)
      : ring_(std::move(ring)), cameras_(cameras), arena_(std::size_t{buffers} * kBufferBytes) {
    msgs_.resize(cameras.size());
    for (msghdr& m : msgs_) {
      m = {};
      m.msg_namelen = sizeof(sockaddr_in);  // the layout of the buffer: header, then this much name
    }
  }

  void arm(std::size_t index) {
    io_uring_sqe* sqe = io_uring_get_sqe(ring_.get());
    if (sqe == nullptr) {
      io_uring_submit(ring_.get());  // never reached with entries >= cameras; kept so a full queue cannot lose an arm
      sqe = io_uring_get_sqe(ring_.get());
    }
    io_uring_prep_recvmsg_multishot(sqe, cameras_[index].fd, &msgs_[index], 0);
    sqe->flags |= IOSQE_BUFFER_SELECT;
    sqe->buf_group = static_cast<std::uint16_t>(kBufferGroup);
    io_uring_sqe_set_data64(sqe, index);
  }

  template <class Handler>
  void reap(const io_uring_cqe& cqe, Handler& handle, EngineCounters& counters, detail::Idle& idle) {
    const std::size_t index = io_uring_cqe_get_data64(&cqe);
    if ((cqe.flags & IORING_CQE_F_BUFFER) != 0 && cqe.res >= 0) {
      const auto id = static_cast<unsigned short>(cqe.flags >> IORING_CQE_BUFFER_SHIFT);
      std::byte* buf = arena_.data() + std::size_t{id} * kBufferBytes;
      if (auto* out = io_uring_recvmsg_validate(buf, cqe.res, &msgs_[index]); out != nullptr) {
        idle.received();
        const auto* payload = static_cast<const std::byte*>(io_uring_recvmsg_payload(out, &msgs_[index]));
        handle(index, std::span<const std::byte>{payload, io_uring_recvmsg_payload_length(out, cqe.res, &msgs_[index])});
      } else {
        ++counters.datagrams;
        ++counters.malformed;
      }
      bufs_->add(buf, static_cast<unsigned>(kBufferBytes), id, static_cast<int>(returned_++));
    } else if (cqe.res < 0 && cqe.res != -ENOBUFS && cqe.res != -ECANCELED) {
      detail::fail(-cqe.res, "multishot recvmsg");
    }
    if ((cqe.flags & IORING_CQE_F_MORE) == 0) {  // the kernel ended this multishot: arm it again
      ++counters.rearms;
      arm(index);
    }
  }

  Ring ring_;
  std::span<Camera> cameras_;
  std::vector<std::byte> arena_;
  std::vector<msghdr> msgs_;
  std::optional<BufRing> bufs_;
  unsigned returned_ = 0;
};

}  // namespace lowlat::io
