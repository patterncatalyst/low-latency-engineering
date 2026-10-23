// flat-dump FILE: decode a file of back-to-back parcel-v1 records with the C++ header and print them
// in the shape of golden-seedN.json (records only; 64-bit fields as decimal strings). verify.sh
// compares this with the Java and Python tools and with the committed JSON.
#include <cstddef>
#include <cstdlib>
#include <exception>
#include <print>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "lowlat/flat/decode.hpp"
#include "lowlat/line/binary_file.hpp"

namespace {

namespace p1 = lowlat::flat::parcel_v1;

nlohmann::json describe(const p1::Parcel& p) {
  return {
      {"schema_id", p.schema_id},
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
      {"barcode", std::string{p1::barcode_view(p)}},
  };
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::println(stderr, "usage: flat-dump FILE");
    return 2;
  }
  try {
    const std::vector<std::byte> raw = lowlat::line::read_binary_file(argv[1]);
    const std::span<const std::byte> bytes{raw};
    if (bytes.size() % p1::kSize != 0) {
      std::println(stderr, "flat-dump: {} bytes is not a whole number of {}-byte records", bytes.size(), p1::kSize);
      return 1;
    }
    nlohmann::json records = nlohmann::json::array();
    for (std::size_t at = 0; at < bytes.size(); at += p1::kSize) {
      const auto parcel = lowlat::flat::decode_memcpy(bytes.subspan(at, p1::kSize));
      if (!parcel) {
        std::println(stderr, "flat-dump: record at {}: {}", at, p1::to_string(parcel.error()));
        return 1;
      }
      records.push_back(describe(*parcel));
    }
    std::println("{}", nlohmann::json{{"records", records}}.dump(2));
    return EXIT_SUCCESS;
  } catch (const std::exception& e) {
    std::println(stderr, "flat-dump: {}", e.what());
    return EXIT_FAILURE;
  }
}
