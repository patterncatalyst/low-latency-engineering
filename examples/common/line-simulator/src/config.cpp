#include "lowlat/line/config.hpp"

#include <cmath>
#include <format>
#include <stdexcept>

#include "lowlat/line/cli.hpp"

namespace lowlat::line {
namespace {

using cli::fail;
using cli::number;

double positive(std::string_view option, std::string_view text) {
  const double v = number<double>(option, text);
  if (!std::isfinite(v) || v <= 0.0) fail(std::format("{} must be > 0", option));
  return v;
}

}  // namespace

Config parse_args(std::span<const std::string_view> args) {
  Config c;
  for (std::size_t i = 0; i < args.size(); ++i) {
    const std::string_view opt = args[i];
    if (opt == "--quiet") {
      c.quiet = true;
      continue;
    }
    if (!opt.starts_with("--")) fail(std::format("unexpected argument '{}'", opt));
    if (i + 1 >= args.size()) fail(std::format("{} needs a value", opt));
    const std::string_view val = args[++i];

    if (opt == "--rate") {
      c.rate_hz = number<std::uint32_t>(opt, val);
      if (c.rate_hz == 0 || c.rate_hz > 1'000'000'000) fail("--rate must be 1..1000000000 Hz");
    } else if (opt == "--duration") {
      c.duration_s = positive(opt, val);
    } else if (opt == "--belt-speed-mps") {
      c.belt_speed_mps = positive(opt, val);
    } else if (opt == "--scan-to-divert-m") {
      c.scan_to_divert_m = positive(opt, val);
    } else if (opt == "--encoder-ppm") {
      c.encoder_ppm = number<std::uint32_t>(opt, val);
      if (c.encoder_ppm == 0) fail("--encoder-ppm must be > 0");
    } else if (opt == "--seed") {
      c.seed = number<std::uint64_t>(opt, val);
    } else if (opt == "--dest") {
      if (val.find(':') == std::string_view::npos) fail("--dest must be host:port");
      c.dest = val;
    } else if (opt == "--report") {
      if (val.empty()) fail("--report needs a file name");
      c.report = std::filesystem::path{val};
    } else {
      fail(std::format("unknown option '{}'", opt));
    }
  }
  return c;
}

std::string_view usage() noexcept {
  return R"(usage: line-simulator [options]

  --rate HZ              parcels per second (integer)            [1000]
  --duration S           run length in seconds                   [10]
  --belt-speed-mps V     belt speed, metres per second           [2.5]
  --scan-to-divert-m D   scanner-to-diverter distance, metres    [1.2]
  --encoder-ppm N        encoder pulses per metre of belt        [1000]
  --seed N               seed of the parcel generator            [42]
  --dest HOST:PORT       UDP destination (IPv4)                  [127.0.0.1:47000]
  --report FILE          write the emit-lateness report (needs $LOWLAT_PROFILE)
  --quiet                print only the final summary line
  -h, --help             this text
)";
}

std::uint64_t parcel_count(const Config& c) noexcept {
  return static_cast<std::uint64_t>(std::llround(c.duration_s * static_cast<double>(c.rate_hz)));
}

}  // namespace lowlat::line
