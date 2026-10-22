// Tests of the C++ measurement kit: correction maths, report shape, golden
// fixture, and cross-decoding of the other kits' golden reports.
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <print>
#include <stdexcept>
#include <string>

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

// Golden fixture: i * 1000 ns for i = 1..10000, written into the source tree.
TEST_F(Measure, GoldenFixtureRoundTrip) {
  Recorder r{"measure-fixtures", "golden"};
  for (std::int64_t i = 1; i <= 10'000; ++i) r.record(i * 1000);
  const json doc = r.write_report(kFixtures / "cpp-golden.json");

  std::ifstream in{kFixtures / "cpp-golden.json"};
  const json written = json::parse(in);
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

// Cross-kit check: the Java and Python goldens must decode to the same
// percentiles as the C++ one, within HdrHistogram's equivalent-value range.
TEST_F(Measure, OtherKitsGoldensAgree) {
  std::ifstream cpp_in{kFixtures / "cpp-golden.json"};
  if (!cpp_in) GTEST_SKIP() << "cpp-golden.json not written yet (run GoldenFixtureRoundTrip first)";
  const json cpp = json::parse(cpp_in);
  const auto cpp_h = lowlat::measure::decode(cpp["hdr_histogram"].get<std::string>());

  int compared = 0;
  for (const char* name : {"java-golden.json", "python-golden.json"}) {
    std::ifstream in{kFixtures / name};
    if (!in) {
      std::println("[  SKIPPED ] {} absent", name);
      continue;
    }
    const json other = json::parse(in);
    const auto h = lowlat::measure::decode(other["hdr_histogram"].get<std::string>());
    EXPECT_EQ(hdr_total_count(h.get()), hdr_total_count(cpp_h.get())) << name;
    for (const double pct : {50.0, 90.0, 99.0, 99.9}) {
      EXPECT_TRUE(hdr_values_are_equivalent(cpp_h.get(), hdr_value_at_percentile(cpp_h.get(), pct),
                                            hdr_value_at_percentile(h.get(), pct)))
          << name << " p" << pct;
    }
    EXPECT_TRUE(hdr_values_are_equivalent(cpp_h.get(), hdr_max(cpp_h.get()), hdr_max(h.get()))) << name;
    ++compared;
  }
  if (compared == 0) GTEST_SKIP() << "no java-golden.json or python-golden.json present yet";
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
