// RAII file descriptor: closed on destruction, never copied.
#pragma once

#include <unistd.h>

#include <utility>

namespace lowlat::line {

class Fd {
 public:
  explicit Fd(int fd) noexcept : fd_(fd) {}
  Fd(Fd&& other) noexcept : fd_(std::exchange(other.fd_, -1)) {}
  Fd(const Fd&) = delete;
  Fd& operator=(const Fd&) = delete;
  Fd& operator=(Fd&&) = delete;
  ~Fd() {
    if (fd_ >= 0) ::close(fd_);
  }
  [[nodiscard]] int get() const noexcept { return fd_; }

 private:
  int fd_;
};

}  // namespace lowlat::line
