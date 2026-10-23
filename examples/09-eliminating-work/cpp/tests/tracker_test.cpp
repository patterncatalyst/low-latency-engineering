// Ch9 unit tests: tracker logic (insert, update, erase, sweep, expire) for every shape, SSCC packing against
// the parcel-v1 golden barcodes, record and counter layout, and exact allocation counts. Deterministic
// and CI-safe: no PMU, no timing, no pinning.
#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>
#include <string>
#include <thread>
#include <vector>

#include "lowlat/eliminating/alloc_counter.hpp"
#include "lowlat/eliminating/counters.hpp"
#include "lowlat/eliminating/keys.hpp"
#include "lowlat/eliminating/placement.hpp"
#include "lowlat/eliminating/records.hpp"
#include "lowlat/eliminating/sscc.hpp"
#include "lowlat/eliminating/tracker.hpp"

namespace el = lowlat::eliminating;

// --- SSCC packing -----------------------------------------------------------------------------------

TEST(Sscc, PacksAndFormatsRoundTrip) {
  EXPECT_EQ(el::pack_sscc("000000000000000042"), 42U);
  EXPECT_EQ(el::pack_sscc("999999999999999999"), 999'999'999'999'999'999ULL);
  EXPECT_EQ(el::format_sscc_string(42), "000000000000000042");
  EXPECT_EQ(el::format_sscc_string(999'999'999'999'999'999ULL), "999999999999999999");
}

TEST(Sscc, RejectsAnythingButEighteenDigits) {
  for (const char* bad : {"", "1234567", "12345678901234567", "1234567890123456789", "12345678901234567x",
                          "+23456789012345678", "-23456789012345678", " 23456789012345678"}) {
    EXPECT_FALSE(el::pack_sscc(bad)) << bad;
  }
}

TEST(Sscc, GoldenBarcodesPackToTheirDigits) {
  std::size_t checked = 0;
  for (const char* seed : {"1", "42", "2026"}) {
    const auto path = std::filesystem::path{LOWLAT_FLAT_GOLDEN_DIR} / (std::string{"golden-seed"} + seed + ".json");
    std::ifstream in{path};
    ASSERT_TRUE(in) << path;
    const auto golden = nlohmann::json::parse(in);
    for (const auto& record : golden.at("records")) {
      const std::string barcode = record.at("barcode");
      const auto packed = el::pack_sscc(barcode);
      ASSERT_TRUE(packed) << barcode;
      EXPECT_EQ(*packed, std::stoull(barcode)) << barcode;
      EXPECT_EQ(el::format_sscc_string(*packed), barcode);
      ++checked;
    }
  }
  EXPECT_EQ(checked, 24U);  // 3 seeds x 8 records
}

TEST(Sscc, SeededKeysAreDistinctAndEighteenDigits) {
  const el::Keys keys = el::make_keys(5'000, 7);
  std::vector<std::uint64_t> sorted = keys.packed;
  std::ranges::sort(sorted);
  EXPECT_EQ(std::ranges::adjacent_find(sorted), sorted.end());
  for (std::size_t i = 0; i < keys.size(); ++i) {
    ASSERT_EQ(keys.text[i].size(), el::kSsccDigits);
    ASSERT_EQ(el::pack_sscc(keys.text[i]), keys.packed[i]);
  }
}

// --- layout -----------------------------------------------------------------------------------------

TEST(Layout, FatRecordIsEightyBytesAndHotColdSplitsIt) {
  EXPECT_EQ(sizeof(el::FatRecord), 80U);
  EXPECT_EQ(alignof(el::FatRecord), 8U);
  EXPECT_EQ(offsetof(el::FatRecord, due_tick), 8U);
  EXPECT_EQ(offsetof(el::FatRecord, state), 52U);
  // Hot columns: due_tick (8 B) + state (1 B) per slot, against 80 B for the whole record.
  EXPECT_EQ(sizeof(std::uint64_t) + sizeof(el::State), 9U);
  EXPECT_LT(sizeof(el::ColdFields), sizeof(el::FatRecord));
}

TEST(Layout, CameraCountersAreSpacedAsNamed) {
  EXPECT_EQ(sizeof(el::LinePaddedCamera), 64U);
  EXPECT_EQ(sizeof(el::PairPaddedCamera), 128U);
  EXPECT_EQ(alignof(el::PairPaddedCamera), 128U);

  // Adjacent: all five read counters in one 64-byte line, the no-read counters in the next, whatever the heap does.
  const auto line_of = [](const void* p) { return reinterpret_cast<std::uintptr_t>(p) / el::kLine; };
  const auto adjacent = std::make_unique<el::AdjacentBank>();
  EXPECT_EQ(alignof(el::AdjacentBank), el::kLine);
  EXPECT_EQ(reinterpret_cast<std::uintptr_t>(adjacent.get()) % el::kLine, 0U);
  for (std::size_t c = 1; c < el::kCameras; ++c) {
    EXPECT_EQ(line_of(&adjacent->reads[0]), line_of(&adjacent->reads[c])) << c;
    EXPECT_EQ(line_of(&adjacent->no_reads[0]), line_of(&adjacent->no_reads[c])) << c;
  }
  EXPECT_NE(line_of(&adjacent->reads[0]), line_of(&adjacent->no_reads[0]));

  const auto line = el::make_bank<el::LinePaddedCamera>();
  const auto pair = el::make_bank<el::PairPaddedCamera>();
  const auto addr = [](const auto& camera) { return reinterpret_cast<std::uintptr_t>(&camera); };
  for (std::size_t a = 0; a < el::kCameras; ++a) {
    for (std::size_t b = a + 1; b < el::kCameras; ++b) {
      EXPECT_FALSE(el::share_line(*line, a, b, el::kLine)) << a << "," << b;
      EXPECT_FALSE(el::share_line(*pair, a, b, el::kLinePair)) << a << "," << b;  // not even the same line pair
      EXPECT_EQ(addr((*pair)[b]) - addr((*pair)[a]), (b - a) * el::kLinePair);   // pair-padded: 128 B apart
    }
  }
}

TEST(Layout, EveryCameraKeepsItsOwnCountUnderConcurrentWriters) {
  constexpr std::uint64_t kIncrements = 200'000;
  const auto bank = el::make_bank<el::PairPaddedCamera>();
  {
    std::vector<std::jthread> cameras;
    for (std::size_t c = 0; c < el::kCameras; ++c) {
      cameras.emplace_back([&bank, c] {
        for (std::uint64_t i = 0; i < kIncrements; ++i) {
          if (i % 32 == 31) (*bank)[c].bump_no_read(); else (*bank)[c].bump_read();
        }
      });
    }
  }  // jthreads join: the happens-before edge for the reads below
  for (const auto& camera : *bank) {
    EXPECT_EQ(camera.total(), kIncrements);
    EXPECT_EQ(camera.no_reads.load(), kIncrements / 32);
  }
}

TEST(Placement, ParsesCpuLists) {
  EXPECT_EQ(el::parse_cpu_list("2,4,6"), (std::vector<int>{2, 4, 6}));
  EXPECT_EQ(el::parse_cpu_list("0"), (std::vector<int>{0}));
  EXPECT_THROW((void)el::parse_cpu_list("2,,4"), std::invalid_argument);
  EXPECT_THROW((void)el::parse_cpu_list("x"), std::invalid_argument);
}

// --- tracker logic, every shape ---------------------------------------------------------------------

template <class T>
class TrackerTest : public testing::Test {};
using Shapes = testing::Types<el::NodeTracker, el::FlatTracker<el::FatTable>, el::HotColdTracker>;
TYPED_TEST_SUITE(TrackerTest, Shapes);

TYPED_TEST(TrackerTest, InsertsUpdatesAndFinds) {
  TypeParam tracker{16};
  const el::Keys keys = el::make_keys(8, 1);
  for (std::size_t i = 0; i < 8; ++i) EXPECT_EQ(tracker.track(el::scan_of(keys, i)), el::Tracked::inserted);
  EXPECT_EQ(tracker.size(), 8U);
  EXPECT_EQ(tracker.track(el::scan_of(keys, 3)), el::Tracked::updated);  // same barcode: no second entry
  EXPECT_EQ(tracker.size(), 8U);
  for (std::size_t i = 0; i < 8; ++i) EXPECT_EQ(tracker.find_state(keys.text[i]), el::State::in_flight);
  EXPECT_EQ(tracker.find_state("000000000000000001"), el::State::empty);
  el::Scan malformed = el::scan_of(keys, 0);
  malformed.barcode = "not-a-barcode";
  EXPECT_EQ(tracker.track(malformed), el::Tracked::rejected);
  EXPECT_EQ(tracker.size(), 8U);
}

TYPED_TEST(TrackerTest, RescanMovesTheDueTick) {
  TypeParam tracker{4};
  const el::Keys keys = el::make_keys(1, 1);
  el::Scan scan = el::scan_of(keys, 0);
  scan.tick = 100;
  (void)tracker.track(scan);
  EXPECT_EQ(tracker.sweep_due(100 + el::kDivertTicks - 1), 0U);
  EXPECT_EQ(tracker.sweep_due(100 + el::kDivertTicks), 1U);
  scan.tick = 5'000;  // scanned again further down the belt: due later
  EXPECT_EQ(tracker.track(scan), el::Tracked::updated);
  EXPECT_EQ(tracker.sweep_due(100 + el::kDivertTicks), 0U);
  EXPECT_EQ(tracker.sweep_due(5'000 + el::kDivertTicks), 1U);
}

TYPED_TEST(TrackerTest, EraseAndSlotReuse) {
  TypeParam tracker{8};
  const el::Keys keys = el::make_keys(6, 2);
  for (std::size_t i = 0; i < 4; ++i) (void)tracker.track(el::scan_of(keys, i));
  EXPECT_TRUE(tracker.erase(keys.text[1]));
  EXPECT_FALSE(tracker.erase(keys.text[1]));  // already gone
  EXPECT_EQ(tracker.find_state(keys.text[1]), el::State::empty);
  EXPECT_EQ(tracker.size(), 3U);
  // A freed slot is reused; the others keep their state.
  EXPECT_EQ(tracker.track(el::scan_of(keys, 4)), el::Tracked::inserted);
  EXPECT_EQ(tracker.size(), 4U);
  for (const std::size_t i : {0U, 2U, 3U, 4U}) EXPECT_EQ(tracker.find_state(keys.text[i]), el::State::in_flight);
}

TYPED_TEST(TrackerTest, SweepCountsOnlyWhatIsDue) {
  TypeParam tracker{64};
  const el::Keys keys = el::make_keys(50, 3);
  for (std::size_t i = 0; i < 50; ++i) (void)tracker.track(el::scan_of(keys, i));  // scan tick i, due at i + 1200
  EXPECT_EQ(tracker.sweep_due(el::kDivertTicks - 1), 0U);
  EXPECT_EQ(tracker.sweep_due(el::kDivertTicks), 1U);
  EXPECT_EQ(tracker.sweep_due(el::kDivertTicks + 24), 25U);
  EXPECT_EQ(tracker.sweep_due(1'000'000), 50U);
  (void)tracker.erase(keys.text[0]);
  EXPECT_EQ(tracker.sweep_due(1'000'000), 49U);  // an erased slot is not due
}

TYPED_TEST(TrackerTest, ExpireErasesWhatIsDue) {
  TypeParam tracker{64};
  const el::Keys keys = el::make_keys(50, 4);
  for (std::size_t i = 0; i < 50; ++i) (void)tracker.track(el::scan_of(keys, i));
  EXPECT_EQ(tracker.expire(el::kDivertTicks + 9), 10U);
  EXPECT_EQ(tracker.size(), 40U);
  for (std::size_t i = 0; i < 10; ++i) EXPECT_EQ(tracker.find_state(keys.text[i]), el::State::empty);
  for (std::size_t i = 10; i < 50; ++i) EXPECT_EQ(tracker.find_state(keys.text[i]), el::State::in_flight);
  EXPECT_EQ(tracker.expire(el::kDivertTicks + 9), 0U);  // nothing more is due
}

TYPED_TEST(TrackerTest, SlidingWindowKeepsTheLineInFlightCount) {
  // The line tracker: 100 in flight, one in and one out per step, for many wraps of the key ring.
  constexpr std::size_t kRing = 1'000;
  constexpr std::size_t kWindow = 100;
  TypeParam tracker{kWindow + 8};
  const el::Keys keys = el::make_keys(kRing, 5);
  for (std::size_t i = kRing - kWindow; i < kRing; ++i) (void)tracker.track(el::scan_of(keys, i));
  for (std::size_t i = 0; i < 5 * kRing; ++i) {
    const std::size_t pos = i % kRing;
    ASSERT_EQ(tracker.track(el::scan_of(keys, pos)), el::Tracked::inserted);
    ASSERT_TRUE(tracker.erase(keys.text[(pos + kRing - kWindow) % kRing]));
    ASSERT_EQ(tracker.size(), kWindow);
  }
}

// --- the Q1-style tables agree on a sweep -----------------------------------------------------------

TEST(Tables, FatAndHotColdSweepTheSameCount) {
  const el::Keys keys = el::make_keys(2'000, 6);
  el::FatTable fat;
  el::HotColdTable hot_cold;
  for (std::size_t i = 0; i < keys.size(); ++i) {
    const el::FatRecord record = el::make_record(el::scan_of(keys, i), keys.packed[i]);
    (void)fat.insert(record);
    (void)hot_cold.insert(record);
  }
  fat.erase(10);
  hot_cold.erase(10);
  for (const std::uint64_t tick : {0ULL, 1'200ULL, 2'000ULL, 3'199ULL, 5'000ULL}) {
    EXPECT_EQ(fat.sweep_due(tick), hot_cold.sweep_due(tick)) << tick;
  }
  EXPECT_EQ(fat.sweep_due(5'000), 1'999U);
}

// --- exact allocation counts ------------------------------------------------------------------------

TEST(Allocations, NodeMapAllocatesTwicePerInsertAndFlatMapNeverAfterReserve) {
  constexpr std::size_t kN = 1'000;
  const el::Keys keys = el::make_keys(kN, 8);
  el::NodeTracker node{kN};
  el::HotColdTracker flat{kN};

  const auto node_before = el::alloc::snapshot();
  for (std::size_t i = 0; i < kN; ++i) (void)node.track(el::scan_of(keys, i));
  const auto node_used = el::alloc::since(node_before);
  // One node and one heap buffer for the 18-character key (past libstdc++'s 15-character small string).
  EXPECT_EQ(node_used.allocations, 2 * kN);

  const auto flat_before = el::alloc::snapshot();
  for (std::size_t i = 0; i < kN; ++i) (void)flat.track(el::scan_of(keys, i));
  for (std::size_t i = 0; i < kN; i += 2) (void)flat.erase(keys.text[i]);
  for (std::size_t i = 0; i < kN; i += 2) (void)flat.track(el::scan_of(keys, i));
  EXPECT_EQ(el::alloc::since(flat_before).allocations, 0U);

  // Updates allocate in neither shape.
  const auto update_before = el::alloc::snapshot();
  for (std::size_t i = 0; i < kN; ++i) {
    (void)node.track(el::scan_of(keys, i));
    (void)flat.track(el::scan_of(keys, i));
  }
  EXPECT_EQ(el::alloc::since(update_before).allocations, 0U);
}
