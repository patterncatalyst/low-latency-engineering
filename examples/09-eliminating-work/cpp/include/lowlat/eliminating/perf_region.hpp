// The counted region of `perf stat --control` (examples/_lib/lib.sh perf_region): when verify.sh runs a
// binary under perf_region, LOWLAT_PERF_CTL and LOWLAT_PERF_ACK name two FIFOs. enable() and disable()
// bracket the measured loop, so setup (building a 1,000,000-parcel table) is not counted. Without the
// variables the region is a no-op.
#pragma once

#include <fcntl.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <string>
#include <string_view>

namespace lowlat::eliminating {

class PerfRegion {
 public:
  PerfRegion() {
    const char* ctl = std::getenv("LOWLAT_PERF_CTL");
    const char* ack = std::getenv("LOWLAT_PERF_ACK");
    if (ctl != nullptr && ack != nullptr) {
      ctl_ = ::open(ctl, O_WRONLY | O_CLOEXEC);
      ack_ = ::open(ack, O_RDONLY | O_CLOEXEC);
      if (ctl_ < 0 || ack_ < 0) throw std::runtime_error("cannot open the perf control FIFOs");
    }
  }
  PerfRegion(const PerfRegion&) = delete;
  PerfRegion& operator=(const PerfRegion&) = delete;
  ~PerfRegion() {
    if (ctl_ >= 0) ::close(ctl_);
    if (ack_ >= 0) ::close(ack_);
  }

  [[nodiscard]] bool active() const noexcept { return ctl_ >= 0; }
  void enable() const { send("enable\n"); }
  void disable() const { send("disable\n"); }

  /// Tells perf_region how many operations the counted region covered (the divisor of per_op).
  static void report_ops(std::uint64_t ops) {
    if (const char* path = std::getenv("LOWLAT_OPS_FILE")) std::ofstream{path} << ops << '\n';
  }

 private:
  void send(std::string_view word) const {
    if (ctl_ < 0) return;
    if (::write(ctl_, word.data(), word.size()) != static_cast<ssize_t>(word.size())) {
      throw std::runtime_error("perf control write failed");
    }
    char reply[8];  // "ack\n"; wait for it so the region starts or ends before we go on
    if (::read(ack_, reply, sizeof reply) <= 0) throw std::runtime_error("perf did not acknowledge");
  }

  int ctl_ = -1;
  int ack_ = -1;
};

}  // namespace lowlat::eliminating
