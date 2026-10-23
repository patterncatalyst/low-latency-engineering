// The tracker's wave handling under each free policy, and the report-variant names.
#include <gtest/gtest.h>

#include <string>

#include "lowlat/gctails/tracker.hpp"

namespace gc = lowlat::gctails;

namespace {

gc::Settings small() {
  return {.rate = 1'000, .wave_parcels = 50, .entry_bytes = 64, .stages = 3, .in_flight_ms = 100};
}

void feed(gc::Tracker& tracker, std::uint64_t parcels) {
  for (std::uint64_t i = 0; i < parcels; ++i) (void)tracker.track(gc::synthetic_barcode(i), i);
}

}  // namespace

TEST(GcTailsTracker, PolicyNamesAreTheReportVariants) {
  EXPECT_EQ(gc::parse_policy("bulk-free"), gc::Policy::bulk_free);
  EXPECT_EQ(gc::parse_policy("deferred-free"), gc::Policy::deferred_free);
  EXPECT_EQ(gc::parse_policy("no-free"), gc::Policy::no_free);
  EXPECT_FALSE(gc::parse_policy("zgc").has_value());
  EXPECT_EQ(gc::name(gc::Policy::deferred_free), "deferred-free");
}

TEST(GcTailsTracker, SyntheticBarcodesHaveTheSsccShape) {
  EXPECT_EQ(gc::synthetic_barcode(0).size(), 18U);
  EXPECT_EQ(gc::synthetic_barcode(123'456'789), "000000001234567890");
}

TEST(GcTailsTracker, BulkFreeDestroysTheDeadWaveInTheClosingCall) {
  gc::Tracker tracker{gc::Policy::bulk_free, small()};
  feed(tracker, 175);  // waves close at 50, 100, 150; the first close retires nothing, the next two 50 entries each
  EXPECT_EQ(tracker.waves_closed(), 3U);
  EXPECT_EQ(tracker.destroyed_inline(), 100U);
  EXPECT_EQ(tracker.reclaimed(), 0U);
}

TEST(GcTailsTracker, DeferredFreeDestroysOnTheReclaimerThread) {
  gc::Tracker tracker{gc::Policy::deferred_free, small()};
  feed(tracker, 275);  // five waves closed, the last four retire 50 entries each
  tracker.finish();    // joins the reclaimer after it has drained its queue
  EXPECT_EQ(tracker.waves_closed(), 5U);
  EXPECT_EQ(tracker.destroyed_inline(), 0U);
  EXPECT_EQ(tracker.reclaimed(), 200U);
}

TEST(GcTailsTracker, NoFreeKeepsEveryDeadWave) {
  gc::Tracker tracker{gc::Policy::no_free, small()};
  feed(tracker, 275);
  EXPECT_EQ(tracker.retained(), 200U);
  EXPECT_EQ(tracker.destroyed_inline(), 0U);
  EXPECT_EQ(tracker.reclaimed(), 0U);
}

TEST(GcTailsTracker, LaneIsTheCommonLookup) {
  gc::Tracker tracker{gc::Policy::no_free, small()};
  const std::string barcode = gc::synthetic_barcode(77);
  EXPECT_EQ(tracker.track(barcode, 1), 77U % 8U);
}
