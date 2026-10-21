#include "lowlat/measure/recorder.hpp"

#include <hdr/hdr_histogram_log.h>

#include <cstdlib>
#include <format>
#include <fstream>
#include <print>
#include <stdexcept>
#include <utility>

#ifndef LOWLAT_MEASURE_BUILD_FLAGS
#define LOWLAT_MEASURE_BUILD_FLAGS ""
#endif

namespace lowlat::measure {
namespace {

// Compiler identification for build.compiler: name, version and language level.
std::string compiler_string() {
#if defined(__clang__)
  return std::format("clang {} (C++ __cplusplus={})", __clang_version__, __cplusplus);
#else
  return std::format("g++ {} (C++ __cplusplus={})", __VERSION__, __cplusplus);
#endif
}

// hdr_log_encode returns a malloc'd C string.
using CString = std::unique_ptr<char, decltype(&std::free)>;

std::string encode(const hdr_histogram& h) {
  char* raw = nullptr;
  // The C API takes a non-const pointer although encoding does not modify it.
  if (const int rc = hdr_log_encode(const_cast<hdr_histogram*>(&h), &raw); rc != 0) {
    throw std::runtime_error(std::format("hdr_log_encode failed ({})", rc));
  }
  const CString owner{raw, &std::free};
  return owner.get();
}

}  // namespace

Histogram make_histogram() {
  hdr_histogram* raw = nullptr;
  if (const int rc = hdr_init(kLowestTrackableNs, kHighestTrackableNs, kSignificantDigits, &raw); rc != 0) {
    throw std::runtime_error(std::format("hdr_init failed ({})", rc));
  }
  return Histogram{raw, &hdr_close};
}

Histogram decode(std::string_view base64) {
  // hdr_log_decode wants a mutable buffer; copy the view.
  std::string buffer{base64};
  hdr_histogram* raw = nullptr;
  if (const int rc = hdr_log_decode(&raw, buffer.data(), buffer.size()); rc != 0) {
    throw std::runtime_error(std::format("hdr_log_decode failed ({}): not a compressed V2 histogram", rc));
  }
  return Histogram{raw, &hdr_close};
}

nlohmann::json load_profile() {
  const char* const path = std::getenv("LOWLAT_PROFILE");
  if (path == nullptr || *path == '\0') {
    throw std::runtime_error(
        "LOWLAT_PROFILE is not set. A latency number without a machine profile is not publishable: "
        "run `scripts/profile.sh --out FILE` and export LOWLAT_PROFILE=FILE.");
  }
  std::ifstream in{path};
  if (!in) throw std::runtime_error(std::format("LOWLAT_PROFILE={} cannot be opened", path));
  return nlohmann::json::parse(in);
}

Recorder::Recorder(std::string example, std::string variant)
    : example_(std::move(example)), variant_(std::move(variant)), hist_(make_histogram()) {}

void Recorder::record(std::int64_t latency_ns) {
  if (!hdr_record_value(hist_.get(), latency_ns)) {
    throw std::out_of_range(std::format("latency {} ns outside [0, {}]", latency_ns, kHighestTrackableNs));
  }
}

void Recorder::record_corrected(std::int64_t latency_ns, std::int64_t expected_interval_ns) {
  if (!hdr_record_corrected_value(hist_.get(), latency_ns, expected_interval_ns)) {
    throw std::out_of_range(std::format("latency {} ns outside [0, {}]", latency_ns, kHighestTrackableNs));
  }
}

nlohmann::json Recorder::report() const {
  nlohmann::json profile = load_profile();  // fail before doing any other work
  const hdr_histogram* const h = hist_.get();
  return {
      {"schema", "lowlat-report/1"},
      {"example", example_},
      {"language", "cpp"},
      {"variant", variant_},
      {"unit", "ns"},
      {"count", hdr_total_count(h)},
      {"dropped", dropped_},
      {"percentiles",
       {{"p50", hdr_value_at_percentile(h, 50.0)},
        {"p90", hdr_value_at_percentile(h, 90.0)},
        {"p99", hdr_value_at_percentile(h, 99.0)},
        {"p99_9", hdr_value_at_percentile(h, 99.9)},
        {"max", hdr_max(h)}}},
      {"hdr_histogram", encode(*h)},
      {"build",
       {{"compiler", compiler_string()}, {"flags", LOWLAT_MEASURE_BUILD_FLAGS}, {"gil_enabled", nullptr}}},
      {"profile", std::move(profile)},
  };
}

nlohmann::json Recorder::write_report(const std::filesystem::path& path) const {
  nlohmann::json doc = report();
  std::ofstream out{path};
  out << doc.dump(2) << '\n';
  if (!out) throw std::runtime_error(std::format("cannot write report to {}", path.string()));
  return doc;
}

std::string Recorder::summary_line() const {
  const hdr_histogram* const h = hist_.get();
  const auto us = [h](double pct) { return static_cast<double>(hdr_value_at_percentile(h, pct)) / 1e3; };
  return std::format("{:<24} {:<4} {:<16} count={:>9} dropped={:>6} p50={:>9.1f}us p90={:>9.1f}us "
                     "p99={:>9.1f}us p99.9={:>9.1f}us max={:>10.1f}us",
                     example_, "cpp", variant_, hdr_total_count(h), dropped_, us(50.0), us(90.0), us(99.0),
                     us(99.9), static_cast<double>(hdr_max(h)) / 1e3);
}

void Recorder::print_summary() const { std::println("{}", summary_line()); }

}  // namespace lowlat::measure
