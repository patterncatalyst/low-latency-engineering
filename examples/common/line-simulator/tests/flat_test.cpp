// Tests of the flat wire contract (contracts/flat/parcel-v1): layout, encode and
// decode, the committed golden bytes, and the simulator's --wire flat output.
//
// LOWLAT_REGEN_GOLDEN=1 rewrites the golden files in contracts/flat/parcel-v1;
// without it they are only read.
#include <gtest/gtest.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <format>
#include <fstream>
#include <iterator>
#include <limits>
#include <nlohmann/json.hpp>
#include <string>
#include <vector>

#include "lowlat/line/config.hpp"
#include "lowlat/line/fd.hpp"
#include "lowlat/line/simulator.hpp"
#include "lowlat/line/v1/parcel.pb.h"
#include "parcel-v1/parcel_v1.hpp"

namespace line = lowlat::line;
namespace p1 = lowlat::flat::parcel_v1;
using nlohmann::json;

namespace {

constexpr std::array<std::uint64_t, 3> kGoldenSeeds{1, 42, 2026};
constexpr std::size_t kGoldenRecords = 8;

// splitmix64 (public domain, Vigna): a generator whose output is fixed by its
// definition, unlike std::*_distribution, so the golden files do not depend on
// the standard library.
class SplitMix64 {
 public:
  explicit SplitMix64(std::uint64_t seed) : state_(seed) {}
  std::uint64_t next() {
    std::uint64_t z = (state_ += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
  }

 private:
  std::uint64_t state_;
};

p1::Parcel extremes() {
  p1::Parcel p;
  p.weight_g = std::numeric_limits<std::uint32_t>::max();
  p.seq = std::numeric_limits<std::uint64_t>::max();
  p.intended_emit_ns = std::numeric_limits<std::int64_t>::min();
  p.actual_emit_ns = std::numeric_limits<std::int64_t>::max();
  p.encoder_tick = 0;
  p.length_mm = p.width_mm = p.height_mm = p.scan_confidence_permille = std::numeric_limits<std::uint32_t>::max();
  p.barcode.fill('0');
  return p;
}

p1::Parcel random_parcel(SplitMix64& g) {
  p1::Parcel p;
  p.weight_g = static_cast<std::uint32_t>(g.next());
  p.seq = g.next();
  p.intended_emit_ns = static_cast<std::int64_t>(g.next());
  p.actual_emit_ns = static_cast<std::int64_t>(g.next());
  p.encoder_tick = g.next();
  p.length_mm = static_cast<std::uint32_t>(g.next());
  p.width_mm = static_cast<std::uint32_t>(g.next());
  p.height_mm = static_cast<std::uint32_t>(g.next());
  p.scan_confidence_permille = static_cast<std::uint32_t>(g.next());
  for (char& c : p.barcode) c = static_cast<char>('0' + g.next() % 10);
  return p;
}

std::vector<p1::Parcel> golden_records(std::uint64_t seed) {
  SplitMix64 g{seed};
  std::vector<p1::Parcel> out{extremes()};
  while (out.size() < kGoldenRecords) out.push_back(random_parcel(g));
  return out;
}

json to_json(const p1::Parcel& p) {
  // 64-bit values as decimal strings: a JSON number loses precision above 2^53 in many readers.
  return json{{"schema_id", p.schema_id},
              {"version", p.version},
              {"weight_g", p.weight_g},
              {"seq", std::to_string(p.seq)},
              {"intended_emit_ns", std::to_string(p.intended_emit_ns)},
              {"actual_emit_ns", std::to_string(p.actual_emit_ns)},
              {"encoder_tick", std::to_string(p.encoder_tick)},
              {"length_mm", p.length_mm},
              {"width_mm", p.width_mm},
              {"height_mm", p.height_mm},
              {"scan_confidence_permille", p.scan_confidence_permille},
              {"barcode", std::string{p1::barcode_view(p)}}};
}

std::filesystem::path golden(std::uint64_t seed, const char* ext) {
  return std::filesystem::path{LOWLAT_FLAT_GOLDEN_DIR} / std::format("golden-seed{}.{}", seed, ext);
}

std::vector<std::byte> read_bytes(const std::filesystem::path& path) {
  std::ifstream in{path, std::ios::binary};
  EXPECT_TRUE(in) << path;
  const std::vector<char> raw{std::istreambuf_iterator<char>{in}, {}};
  std::vector<std::byte> out(raw.size());
  std::ranges::transform(raw, out.begin(), [](char c) { return static_cast<std::byte>(c); });
  return out;
}

bool regen() { return std::getenv("LOWLAT_REGEN_GOLDEN") != nullptr; }

}  // namespace

TEST(FlatParcelV1, LayoutIsPinned) {
  EXPECT_EQ(sizeof(p1::Parcel), 80u);
  const p1::Bytes b = p1::encode(p1::Parcel{.weight_g = 0x04030201});
  // schema_id 1 and version 1, little-endian, then weight_g.
  EXPECT_EQ(b[0], std::byte{1});
  EXPECT_EQ(b[1], std::byte{0});
  EXPECT_EQ(b[2], std::byte{1});
  EXPECT_EQ(b[3], std::byte{0});
  EXPECT_EQ(b[4], std::byte{1});
  EXPECT_EQ(b[7], std::byte{4});
}

TEST(FlatParcelV1, EncodeDecodeRoundTrip) {
  SplitMix64 g{7};
  for (int i = 0; i < 100; ++i) {
    const p1::Parcel in = random_parcel(g);
    const auto out = p1::decode(p1::encode(in));
    ASSERT_TRUE(out.has_value());
    EXPECT_EQ(to_json(*out), to_json(in));
    EXPECT_EQ(p1::encode(*out), p1::encode(in));
  }
}

TEST(FlatParcelV1, EncodeForcesHeaderAndZeroReserved) {
  p1::Parcel dirty;
  dirty.schema_id = 99;
  dirty.version = 99;
  dirty.reserved.fill(std::byte{0xFF});
  const auto out = p1::decode(p1::encode(dirty));
  ASSERT_TRUE(out.has_value());
  EXPECT_EQ(out->schema_id, p1::kSchemaId);
  EXPECT_EQ(out->version, p1::kVersion);
  EXPECT_EQ(out->reserved, (std::array<std::byte, 6>{}));
}

TEST(FlatParcelV1, DecodeRejectsMalformed) {
  const p1::Bytes good = p1::encode(p1::Parcel{});
  EXPECT_EQ(p1::decode(std::span{good}.first(79)).error(), p1::DecodeError::wrong_size);
  EXPECT_EQ(p1::decode(std::span{good}.first(3)).error(), p1::DecodeError::wrong_size);
  std::vector<std::byte> longer(good.begin(), good.end());
  longer.push_back(std::byte{0});
  EXPECT_EQ(p1::decode(longer).error(), p1::DecodeError::wrong_size);
  p1::Bytes bad = good;
  bad[0] = std::byte{2};
  EXPECT_EQ(p1::decode(bad).error(), p1::DecodeError::wrong_schema);
  bad = good;
  bad[2] = std::byte{2};
  EXPECT_EQ(p1::decode(bad).error(), p1::DecodeError::unsupported_version);
  // A later version is larger: the header says so before the size is checked.
  std::vector<std::byte> v2(96);
  v2[0] = std::byte{1};
  v2[2] = std::byte{2};
  EXPECT_EQ(p1::decode(v2).error(), p1::DecodeError::unsupported_version);
  v2[0] = std::byte{9};
  EXPECT_EQ(p1::decode(v2).error(), p1::DecodeError::wrong_schema);
}

TEST(FlatParcelV1, GoldenFilesAreRegeneratedOnRequest) {
  if (!regen()) GTEST_SKIP() << "set LOWLAT_REGEN_GOLDEN=1 to rewrite contracts/flat/parcel-v1/golden-*";
  for (const auto seed : kGoldenSeeds) {
    const auto recs = golden_records(seed);
    std::ofstream bin{golden(seed, "bin"), std::ios::binary};
    json records = json::array();
    for (const auto& r : recs) {
      const auto bytes = p1::encode(r);
      bin.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
      records.push_back(to_json(r));
    }
    json doc{{"format", "lowlat-flat-golden/1"}, {"schema_id", p1::kSchemaId},   {"version", p1::kVersion},
             {"seed", seed},                     {"record_size", p1::kSize},      {"count", recs.size()},
             {"records", records}};
    std::ofstream{golden(seed, "json")} << doc.dump(2) << '\n';
  }
}

TEST(FlatParcelV1, GoldenBytesDecodeToTheirJson) {
  for (const auto seed : kGoldenSeeds) {
    const auto bytes = read_bytes(golden(seed, "bin"));
    std::ifstream in{golden(seed, "json")};
    const json doc = json::parse(in);
    ASSERT_EQ(bytes.size(), kGoldenRecords * p1::kSize) << "seed " << seed;
    ASSERT_EQ(doc.at("count").get<std::size_t>(), kGoldenRecords);
    for (std::size_t i = 0; i < kGoldenRecords; ++i) {
      const auto rec = std::span<const std::byte>{bytes}.subspan(i * p1::kSize, p1::kSize);
      const auto p = p1::decode(rec);
      ASSERT_TRUE(p.has_value()) << "seed " << seed << " record " << i;
      EXPECT_EQ(to_json(*p), doc.at("records").at(i)) << "seed " << seed << " record " << i;
      // The generator is fixed: encoding the decoded record gives the same bytes.
      EXPECT_TRUE(std::ranges::equal(p1::encode(*p), rec)) << "seed " << seed << " record " << i;
    }
    // And the file is what the generator produces today.
    const auto expect = golden_records(seed);
    for (std::size_t i = 0; i < kGoldenRecords; ++i) {
      const auto rec = std::span<const std::byte>{bytes}.subspan(i * p1::kSize, p1::kSize);
      EXPECT_TRUE(std::ranges::equal(p1::encode(expect[i]), rec)) << "seed " << seed << " record " << i;
    }
  }
}

// --- simulator --wire flat -----------------------------------------------------

namespace {

struct Sink {
  line::Fd fd{::socket(AF_INET, SOCK_DGRAM, 0)};
  std::uint16_t port = 0;

  Sink() {
    EXPECT_GE(fd.get(), 0);
    const int rcvbuf = 4 << 20;
    EXPECT_EQ(::setsockopt(fd.get(), SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf), 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    EXPECT_EQ(::bind(fd.get(), reinterpret_cast<sockaddr*>(&addr), sizeof addr), 0);
    socklen_t len = sizeof addr;
    EXPECT_EQ(::getsockname(fd.get(), reinterpret_cast<sockaddr*>(&addr), &len), 0);
    port = ntohs(addr.sin_port);
  }

  // Everything already queued (the kernel buffer holds a 100-parcel run).
  std::vector<std::vector<std::byte>> drain() {
    std::vector<std::vector<std::byte>> out;
    std::array<std::byte, 2048> buf{};
    for (;;) {
      const ssize_t n = ::recv(fd.get(), buf.data(), buf.size(), MSG_DONTWAIT);
      if (n < 0) break;
      out.emplace_back(buf.begin(), buf.begin() + n);
    }
    return out;
  }
};

std::vector<std::vector<std::byte>> run_wire(line::Wire wire) {
  Sink sink;
  line::Config cfg;
  cfg.rate_hz = 1000;
  cfg.duration_s = 0.1;
  cfg.seed = 5;
  cfg.wire = wire;
  cfg.dest = "127.0.0.1:" + std::to_string(sink.port);
  std::atomic<bool> stop{false};
  lowlat::measure::Recorder lateness{"line-simulator", "emit-lateness"};
  const line::RunResult result = line::run(cfg, stop, lateness);
  EXPECT_EQ(result.sent, 100u);
  return sink.drain();
}

}  // namespace

TEST(Simulator, FlatWireCarriesTheSameParcelsAsProtobuf) {
  const auto flat_dgrams = run_wire(line::Wire::flat);
  const auto pb_dgrams = run_wire(line::Wire::protobuf);
  ASSERT_EQ(flat_dgrams.size(), 100u);
  ASSERT_EQ(pb_dgrams.size(), 100u);
  for (std::size_t i = 0; i < 100; ++i) {
    ASSERT_EQ(flat_dgrams[i].size(), p1::kSize);
    const auto f = p1::decode(flat_dgrams[i]);
    ASSERT_TRUE(f.has_value());
    line::v1::ParcelEvent pb;
    ASSERT_TRUE(pb.ParseFromArray(pb_dgrams[i].data(), static_cast<int>(pb_dgrams[i].size())));
    EXPECT_EQ(f->seq, pb.seq());
    EXPECT_EQ(f->seq, i);
    EXPECT_EQ(p1::barcode_view(*f), pb.barcode());
    EXPECT_EQ(f->weight_g, pb.weight_g());
    EXPECT_EQ(f->length_mm, pb.dims().length_mm());
    EXPECT_EQ(f->width_mm, pb.dims().width_mm());
    EXPECT_EQ(f->height_mm, pb.dims().height_mm());
    EXPECT_EQ(f->scan_confidence_permille, pb.scan_confidence_permille());
    EXPECT_EQ(f->encoder_tick, pb.encoder_tick());
    EXPECT_GE(f->actual_emit_ns, f->intended_emit_ns - 1);
  }
}

TEST(Config, WireOption) {
  using V = std::vector<std::string_view>;
  EXPECT_EQ(line::parse_args(V{}).wire, line::Wire::protobuf);
  EXPECT_EQ(line::parse_args(V{"--wire", "flat"}).wire, line::Wire::flat);
  EXPECT_EQ(line::parse_args(V{"--wire", "protobuf"}).wire, line::Wire::protobuf);
  EXPECT_THROW((void)line::parse_args(V{"--wire", "sbe"}), std::invalid_argument);
}
