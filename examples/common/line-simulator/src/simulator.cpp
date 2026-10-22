#include "lowlat/line/simulator.hpp"

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <format>
#include <memory>
#include <random>
#include <stdexcept>
#include <string>
#include <system_error>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/fd.hpp"
#include "lowlat/line/schedule.hpp"
#include "lowlat/line/sscc.hpp"
#include "lowlat/line/v1/parcel.pb.h"  // generated: contracts/proto/lowlat/line/v1/parcel.proto
#include "parcel-v1/parcel_v1.hpp"

namespace lowlat::line {
namespace {

// Lead between "now" and parcel 0 so the first parcel is not born late.
constexpr std::int64_t kStartLeadNs = 20'000'000;
// GS1 documentation prefix; every barcode is syntactically valid, none is real.
constexpr std::string_view kCompanyPrefix = "0614141";

// A connected UDP socket. connect() on a datagram socket only fixes the peer,
// so each send skips the address lookup; it also makes an absent receiver
// show up as ECONNREFUSED, which run() counts.
Fd open_udp(const std::string& dest) {
  const auto colon = dest.rfind(':');
  const std::string host = dest.substr(0, colon);
  const std::string port = dest.substr(colon + 1);

  addrinfo hints{};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  addrinfo* raw = nullptr;
  if (const int rc = ::getaddrinfo(host.c_str(), port.c_str(), &hints, &raw); rc != 0) {
    throw std::runtime_error(std::format("cannot resolve {}: {}", dest, ::gai_strerror(rc)));
  }
  const std::unique_ptr<addrinfo, decltype(&::freeaddrinfo)> addr{raw, &::freeaddrinfo};

  Fd fd{::socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol)};
  if (fd.get() < 0) throw std::system_error(errno, std::generic_category(), "socket");
  if (::connect(fd.get(), addr->ai_addr, addr->ai_addrlen) != 0) {
    throw std::system_error(errno, std::generic_category(), std::format("connect {}", dest));
  }
  return fd;
}

// Seeded source of plausible parcels: weights log-normal around 2 kg, boxes
// uniform within carton sizes, 97% good reads. The sequence is reproducible
// for a given standard library; distributions are not bit-identical between
// libstdc++ and libc++.
class ParcelFactory {
 public:
  explicit ParcelFactory(std::uint64_t seed) : rng_(seed) {}

  // Everything except actual_emit_ns, which is stamped at send time.
  void fill(v1::ParcelEvent& ev, std::uint64_t seq, std::int64_t intended_ns, std::uint64_t tick) {
    ev.set_seq(seq);
    ev.set_intended_emit_ns(intended_ns);
    ev.set_encoder_tick(tick);
    ev.set_barcode(make_sscc(extension_(rng_), kCompanyPrefix, seq));
    ev.set_weight_g(static_cast<std::uint32_t>(std::clamp(std::llround(weight_(rng_)), 50LL, 30'000LL)));
    auto* d = ev.mutable_dims();
    d->set_length_mm(length_(rng_));
    d->set_width_mm(width_(rng_));
    d->set_height_mm(height_(rng_));
    ev.set_scan_confidence_permille(good_read_(rng_) ? confident_(rng_) : doubtful_(rng_));
  }

 private:
  std::mt19937_64 rng_;
  std::uniform_int_distribution<int> extension_{0, 9};
  std::lognormal_distribution<double> weight_{std::log(2000.0), 0.8};
  std::uniform_int_distribution<std::uint32_t> length_{150, 800};
  std::uniform_int_distribution<std::uint32_t> width_{100, 600};
  std::uniform_int_distribution<std::uint32_t> height_{20, 400};
  std::bernoulli_distribution good_read_{0.97};
  std::uniform_int_distribution<std::uint32_t> confident_{950, 1000};
  std::uniform_int_distribution<std::uint32_t> doubtful_{300, 700};
};

// The same parcel in the flat record. Both wires carry identical values for a
// seed, so a protobuf run and a flat run differ only in the encoding.
flat::parcel_v1::Parcel to_flat(const v1::ParcelEvent& ev) {
  flat::parcel_v1::Parcel p;
  p.weight_g = ev.weight_g();
  p.seq = ev.seq();
  p.intended_emit_ns = ev.intended_emit_ns();
  p.actual_emit_ns = ev.actual_emit_ns();
  p.encoder_tick = ev.encoder_tick();
  p.length_mm = ev.dims().length_mm();
  p.width_mm = ev.dims().width_mm();
  p.height_mm = ev.dims().height_mm();
  p.scan_confidence_permille = ev.scan_confidence_permille();
  const std::string& barcode = ev.barcode();
  if (barcode.size() != p.barcode.size()) throw std::runtime_error("barcode is not 18 characters");
  std::ranges::copy(barcode, p.barcode.begin());
  return p;
}

}  // namespace

RunResult run(const Config& cfg, const std::atomic<bool>& stop, measure::Recorder& emit_lateness) {
  const Fd sock = open_udp(cfg.dest);
  ParcelFactory factory{cfg.seed};
  const Schedule schedule{.t0_ns = monotonic_ns() + kStartLeadNs, .rate_hz = cfg.rate_hz};
  const double pulses_per_metre = static_cast<double>(cfg.encoder_ppm);

  v1::ParcelEvent ev;
  std::array<char, 256> datagram{};  // reused; a ParcelEvent is under 100 bytes, a flat record 80
  RunResult result;

  const std::uint64_t total = parcel_count(cfg);
  for (std::uint64_t i = 0; i < total; ++i) {
    if (stop.load(std::memory_order_relaxed)) {
      result.interrupted = true;
      break;
    }
    const std::int64_t intended = schedule.intended_ns(i);
    // Build the event before sleeping: generation cost stays off the wake-up path.
    factory.fill(ev, i, intended, encoder_tick(intended - schedule.t0_ns, cfg.belt_speed_mps, pulses_per_metre));

    // Sleep to the absolute deadline. A signal wakes us early: stop if asked to,
    // otherwise sleep again to the same deadline. If the deadline has passed
    // this returns at once: the belt does not wait, so neither do we.
    bool woken = false;
    while (!(woken = sleep_until_ns(intended)) && !stop.load(std::memory_order_relaxed)) {
    }
    if (!woken) {
      result.interrupted = true;
      break;
    }

    const std::int64_t actual = monotonic_ns();
    ev.set_actual_emit_ns(actual);
    std::size_t size = 0;
    if (cfg.wire == Wire::flat) {
      const auto bytes = flat::parcel_v1::encode(to_flat(ev));
      size = bytes.size();
      std::memcpy(datagram.data(), bytes.data(), size);
    } else {
      size = ev.ByteSizeLong();
      if (!ev.SerializeToArray(datagram.data(), static_cast<int>(size))) {
        throw std::runtime_error("ParcelEvent does not fit the datagram buffer");
      }
    }
    // MSG_DONTWAIT: a full socket buffer drops this parcel instead of stalling the belt.
    if (::send(sock.get(), datagram.data(), size, MSG_DONTWAIT) == static_cast<ssize_t>(size)) {
      ++result.sent;
    } else {
      ++result.send_errors;
    }
    emit_lateness.record(std::max<std::int64_t>(0, actual - intended));
  }
  emit_lateness.add_dropped(result.send_errors);
  return result;
}

}  // namespace lowlat::line
