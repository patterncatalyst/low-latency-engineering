// Tests of the C++ measurement kit: correction maths, report shape, golden
// fixture, and cross-decoding of the other kits' golden reports.
//
// The golden round trip writes to a temporary file. Setting LOWLAT_REGEN_GOLDEN=1
// rewrites the committed measure-fixtures/cpp-golden.json instead.
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <unistd.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <format>
#include <stdexcept>
#include <string>
#include <string_view>

#include "lowlat/measure/recorder.hpp"

namespace fs = std::filesystem;
using lowlat::measure::Recorder;
using nlohmann::json;

namespace {

const fs::path kFixtures{LOWLAT_FIXTURES_DIR};

class Measure : public testing::Test {
 protected:
  void SetUp() override { setenv("LOWLAT_PROFILE", (kFixtures / "profile.json").c_str(), 1); }
};

// True when no key named "mean" appears anywhere in `j`.
bool has_no_mean(const json& j) {
  if (j.is_object()) {
    for (const auto& [key, value] : j.items()) {
      if (key.contains("mean") || !has_no_mean(value)) return false;
    }
  }
  return true;
}

// The golden dataset: i * 1000 ns for i = 1..10000.
Recorder golden_recorder() {
  Recorder r{"measure-fixtures", "golden"};
  for (std::int64_t i = 1; i <= 10'000; ++i) r.record(i * 1000);
  return r;
}

bool regen_golden() {
  const char* v = std::getenv("LOWLAT_REGEN_GOLDEN");
  return v != nullptr && std::string_view{v} == "1";
}

}  // namespace

// MEASUREMENT.md "Correction test": 1000 x 1 ms, then one 1 s stall.
TEST_F(Measure, CoordinatedOmissionCorrection) {
  constexpr std::int64_t kMs = 1'000'000;
  Recorder plain{"test", "plain"};
  Recorder corrected{"test", "corrected"};
  for (int i = 0; i < 1000; ++i) {
    plain.record(kMs);
    corrected.record_corrected(kMs, kMs);
  }
  plain.record(1000 * kMs);
  corrected.record_corrected(1000 * kMs, kMs);  // 1 + 999 back-filled values

  EXPECT_EQ(corrected.count(), 2000);
  EXPECT_EQ(plain.count(), 1001);

  const auto corrected_p99 = hdr_value_at_percentile(&corrected.histogram(), 99.0);
  const auto plain_p99 = hdr_value_at_percentile(&plain.histogram(), 99.0);
  EXPECT_GT(corrected_p99, kMs);
  EXPECT_TRUE(hdr_values_are_equivalent(&plain.histogram(), plain_p99, kMs)) << "plain p99 = " << plain_p99;
}

TEST_F(Measure, ReportHasRequiredKeysAndNoMean) {
  Recorder r{"test", "shape"};
  r.record(1'000);
  r.record(std::chrono::nanoseconds{2'000});
  r.add_dropped(3);
  const json doc = r.report();

  for (const char* key : {"schema", "example", "language", "variant", "unit", "count", "dropped",
                          "percentiles", "hdr_histogram", "build", "profile"}) {
    EXPECT_TRUE(doc.contains(key)) << key;
  }
  EXPECT_EQ(doc["schema"], "lowlat-report/1");
  EXPECT_EQ(doc["language"], "cpp");
  EXPECT_EQ(doc["unit"], "ns");
  EXPECT_EQ(doc["count"], 2);
  EXPECT_EQ(doc["dropped"], 3);
  EXPECT_TRUE(doc["build"]["gil_enabled"].is_null());
  EXPECT_EQ(doc["profile"]["schema"], "lowlat-profile/1");

  const json& p = doc["percentiles"];
  EXPECT_EQ(p.size(), 5u);
  for (const char* key : {"p50", "p90", "p99", "p99_9", "max"}) {
    EXPECT_TRUE(p.at(key).is_number_integer()) << key;
  }
  EXPECT_TRUE(has_no_mean(doc));
  EXPECT_NE(r.summary_line().find("p99.9="), std::string::npos);
}

TEST_F(Measure, MissingProfileFailsClearly) {
  unsetenv("LOWLAT_PROFILE");
  Recorder r{"test", "noprofile"};
  r.record(1);
  EXPECT_THAT([&] { (void)r.report(); },
              testing::ThrowsMessage<std::runtime_error>(testing::HasSubstr("LOWLAT_PROFILE")));
}

TEST_F(Measure, MalformedProfileIsARuntimeErrorNamingTheFile) {
  const std::string bad = testing::TempDir() + "lowlat-bad-profile.json";
  { std::ofstream{bad} << "{ not json"; }
  setenv("LOWLAT_PROFILE", bad.c_str(), 1);
  Recorder r{"test", "badprofile"};
  r.record(1);
  EXPECT_THAT([&] { (void)r.report(); },
              testing::ThrowsMessage<std::runtime_error>(testing::HasSubstr(bad)));
  fs::remove(bad);
}

TEST_F(Measure, OutOfRangeRecordThrows) {
  Recorder r{"test", "range"};
  EXPECT_THROW(r.record(lowlat::measure::kHighestTrackableNs * 2), std::out_of_range);
  EXPECT_THROW(r.record(-1), std::out_of_range);
}

// Golden fixture round trip. The report goes to a per-process temporary file, or
// to the committed fixture when LOWLAT_REGEN_GOLDEN=1.
TEST_F(Measure, GoldenFixtureRoundTrip) {
  const fs::path out = regen_golden() ? kFixtures / "cpp-golden.json"
                                      : fs::path{testing::TempDir()} /
                                            std::format("cpp-golden-{}.json", ::getpid());
  Recorder r = golden_recorder();
  const json doc = r.write_report(out);

  std::ifstream in{out};
  const json written = json::parse(in);
  in.close();
  if (!regen_golden()) fs::remove(out);
  EXPECT_EQ(written, doc);

  const auto decoded = lowlat::measure::decode(written["hdr_histogram"].get<std::string>());
  EXPECT_EQ(hdr_total_count(decoded.get()), 10'000);
  const auto& p = written["percentiles"];
  EXPECT_EQ(hdr_value_at_percentile(decoded.get(), 50.0), p["p50"].get<std::int64_t>());
  EXPECT_EQ(hdr_value_at_percentile(decoded.get(), 99.0), p["p99"].get<std::int64_t>());
  EXPECT_EQ(hdr_max(decoded.get()), p["max"].get<std::int64_t>());
}

TEST_F(Measure, DecodeRejectsGarbage) {
  EXPECT_THROW((void)lowlat::measure::decode("not a histogram"), std::runtime_error);
}

// Cross-kit check: the committed Java and Python goldens (and the committed C++
// one) must decode to the same percentiles as a report recorded here from the same
// dataset, within HdrHistogram's equivalent-value range. The reference is built in
// the test, so the result does not depend on test order or on a fixture being rewritten.
TEST_F(Measure, CommittedGoldensAgreeWithFreshReport) {
  const Recorder fresh = golden_recorder();
  const hdr_histogram* ref = &fresh.histogram();

  for (const char* name : {"cpp-golden.json", "java-golden.json", "python-golden.json"}) {
    std::ifstream in{kFixtures / name};
    ASSERT_TRUE(in) << name << " is a committed fixture and must exist";
    const json other = json::parse(in);
    const auto h = lowlat::measure::decode(other["hdr_histogram"].get<std::string>());
    EXPECT_EQ(hdr_total_count(h.get()), hdr_total_count(ref)) << name;
    for (const double pct : {50.0, 90.0, 99.0, 99.9}) {
      EXPECT_TRUE(hdr_values_are_equivalent(ref, hdr_value_at_percentile(ref, pct),
                                            hdr_value_at_percentile(h.get(), pct)))
          << name << " p" << pct;
    }
    EXPECT_TRUE(hdr_values_are_equivalent(ref, hdr_max(ref), hdr_max(h.get()))) << name;
  }
}

TEST_F(Measure, NotesAppearOnlyWhenGiven) {
  Recorder r{"t", "v"};
  r.record(1000);
  EXPECT_FALSE(r.report().contains("notes"));
  EXPECT_FALSE(r.report("").contains("notes"));
  const json doc = r.report("reordered=1; rcvbuf_requested=2; rcvbuf_granted=4");
  EXPECT_EQ(doc.at("notes"), "reordered=1; rcvbuf_requested=2; rcvbuf_granted=4");
}

TEST_F(Measure, ModelAppearsOnlyWhenGiven) {
  Recorder r{"t", "v"};
  r.record(1000);
  EXPECT_FALSE(r.report().contains("model"));
  EXPECT_FALSE(r.report("", json::object()).contains("model"));
  EXPECT_FALSE(r.report("", json(nullptr)).contains("model"));
  const json model = {{"law", "Little: L = lambda * W"}, {"W_mean_seconds_modelling_input", 0.25}};
  const json doc = r.report("n", model);
  EXPECT_EQ(doc.at("model"), model);
  EXPECT_EQ(doc.at("notes"), "n");
  EXPECT_TRUE(r.report({}, model).contains("model"));
}

TEST_F(Measure, WriteReportCarriesModel) {
  Recorder r{"t", "v"};
  r.record(1000);
  const json model = {{"law", "Amdahl"}, {"workers", 4}};
  const auto path = fs::temp_directory_path() / "lowlat-model-test.json";
  const json doc = r.write_report(path, "", model);
  std::ifstream in{path};
  const json written = json::parse(in);
  fs::remove(path);
  EXPECT_EQ(written, doc);
  EXPECT_EQ(written.at("model"), model);
  EXPECT_FALSE(written.contains("notes"));
}
