// Unit tests for the deterministic parts of the Ch11 lane: the parcel generator, the counted-frame Task with
// symmetric transfer, the option and CPU-list parsers, and small runs of the three workloads in every model.
// They pin nothing and need no particular host.
#include <gtest/gtest.h>

#include <chrono>
#include <coroutine>
#include <string>
#include <vector>

#include "lowlat/line/consumer.hpp"
#include "lowlat/tasks/frames.hpp"
#include "lowlat/tasks/options.hpp"
#include "lowlat/tasks/parcels.hpp"
#include "lowlat/tasks/placement.hpp"
#include "lowlat/tasks/procinfo.hpp"
#include "lowlat/tasks/workloads.hpp"

namespace lowlat::tasks {
namespace {

using namespace std::chrono_literals;

// ---- the parcel generator ----------------------------------------------------------------------------------------

TEST(Parcels, GeneratorYieldsParcelsInOrderWithValidBarcodes) {
  std::uint64_t expected = 0;
  for (const auto& ev : parcels(25, 1000, 50)) {
    EXPECT_EQ(ev.seq(), expected);
    EXPECT_EQ(ev.intended_emit_ns(), 1000 + static_cast<std::int64_t>(expected) * 50);
    ASSERT_EQ(ev.barcode().size(), 18U);
    EXPECT_LT(line::lane_for(ev.barcode()), line::kLanes);
    ++expected;
  }
  EXPECT_EQ(expected, 25U);
}

TEST(Parcels, ConfidenceDropsOnEveryTwentiethParcel) {
  std::uint64_t doubtful = 0;
  for (const auto& ev : parcels(100)) doubtful += ev.scan_confidence_permille() < 500;
  EXPECT_EQ(doubtful, 5U);
}

// ---- Task<T> and symmetric transfer ---------------------------------------------------------------------------

Task<int> add_one(int x) { co_return x + 1; }

Task<int> chain(int depth) {
  if (depth == 0) co_return 0;
  co_return 1 + co_await chain(depth - 1);
}

Task<int> sum_of_sequential_awaits(int n) {
  int total = 0;
  for (int i = 0; i < n; ++i) total += co_await add_one(i);
  co_return total;
}

Task<int> throws() {
  throw std::runtime_error("boom");
  co_return 0;
}

TEST(Task, ReturnsAValueToTheRoot) {
  auto t = add_one(41);
  t.start();
  ASSERT_TRUE(t.done());
  EXPECT_EQ(t.result(), 42);
}

TEST(Task, AwaitedChainFinishesByTailCallsNotRecursion) {
  auto t = chain(10'000);  // one stack frame per link would be 10,000 deep without symmetric transfer
  t.start();
  ASSERT_TRUE(t.done());
  EXPECT_EQ(t.result(), 10'000);
}

TEST(Task, SequentialAwaitsAddUp) {
  auto t = sum_of_sequential_awaits(1000);
  t.start();
  EXPECT_EQ(t.result(), 1000 * 1001 / 2);
}

TEST(Task, ExceptionsReachTheRoot) {
  auto t = throws();
  t.start();
  ASSERT_TRUE(t.done());
  EXPECT_THROW((void)t.result(), std::runtime_error);
}

Task<> ping(PaddedSlot& slot, std::uint64_t rounds, std::uint64_t& acc, std::coroutine_handle<>& self, std::coroutine_handle<>& peer) {
  for (std::uint64_t j = 0; j < rounds; ++j) {
    slot.v = j;
    co_await Transfer{self, peer};
    acc += slot.v;
  }
}

Task<> pong(PaddedSlot& slot, std::uint64_t& served, std::coroutine_handle<>& self, std::coroutine_handle<>& peer) {
  for (;;) {
    slot.v += 1;
    ++served;
    co_await Transfer{self, peer};
  }
}

TEST(Task, TwoCoroutinesHandTheTurnBackAndForth) {
  PaddedSlot slot;
  std::coroutine_handle<> ha, hb;
  std::uint64_t acc = 0, served = 0;
  Task<> b = pong(slot, served, hb, ha);
  hb = b.handle();
  Task<> a = ping(slot, 100, acc, ha, hb);
  a.start();
  EXPECT_TRUE(a.done());
  EXPECT_EQ(served, 100U);
  EXPECT_EQ(acc, 100U * 101U / 2U);
}

// ---- frame counting -------------------------------------------------------------------------------------------

TEST(Frames, EachParkedFrameIsOneCountedAllocation) {
  const FrameProbe probe = probe_frames(200, 100);
  EXPECT_EQ(probe.parked_frames, 200U);
  EXPECT_EQ(probe.allocations, 200U);  // frames escape into a vector, so none can be elided
  EXPECT_GT(probe.bytes / probe.parked_frames, 0U);
  EXPECT_LE(probe.bytes / probe.parked_frames, 1024U);
  EXPECT_LE(probe.control_allocations, probe.control_frames);  // fewer means the compiler elided some
}

TEST(Frames, FreesMatchAllocationsAfterTheTasksAreDestroyed) {
  const FrameSnapshot before = frame_snapshot();
  {
    std::vector<Task<int>> kept;
    for (int i = 0; i < 50; ++i) kept.push_back(add_one(i));
    EXPECT_EQ(frame_snapshot().allocations - before.allocations, 50U);
  }
  const FrameSnapshot after = frame_snapshot();
  EXPECT_EQ(after.frees - before.frees, 50U);
}

// ---- options and CPU lists --------------------------------------------------------------------------------------

TEST(Options, ParsesKeysAndFlags) {
  std::vector<std::string> storage{"prog", "--variant", "fiber", "--blocking-sleep-in-fiber", "--tasks", "12"};
  std::vector<char*> argv;
  for (auto& s : storage) argv.push_back(s.data());
  auto o = Options::parse(static_cast<int>(argv.size()), argv.data(), 1, {"blocking-sleep-in-fiber"});
  ASSERT_TRUE(o.has_value());
  EXPECT_EQ(o->text("variant", ""), "fiber");
  EXPECT_TRUE(o->flag("blocking-sleep-in-fiber"));
  EXPECT_EQ(o->number("tasks", 0).value(), 12U);
  EXPECT_EQ(o->number("missing", 7).value(), 7U);
}

TEST(Options, RejectsBadInput) {
  std::vector<std::string> storage{"prog", "--tasks", "12abc"};
  std::vector<char*> argv;
  for (auto& s : storage) argv.push_back(s.data());
  auto o = Options::parse(static_cast<int>(argv.size()), argv.data(), 1);
  ASSERT_TRUE(o.has_value());
  EXPECT_FALSE(o->number("tasks", 0).has_value());
  std::vector<std::string> bare{"prog", "tasks"};
  std::vector<char*> argv2{bare[0].data(), bare[1].data()};
  EXPECT_FALSE(Options::parse(2, argv2.data(), 1).has_value());
}

TEST(Placement, ParsesCpuLists) {
  EXPECT_EQ(parse_cpu_list("2,5,9").value(), (std::vector<int>{2, 5, 9}));
  EXPECT_FALSE(parse_cpu_list("").has_value());
  EXPECT_FALSE(parse_cpu_list("2,x").has_value());
  EXPECT_FALSE(parse_cpu_list("-1").has_value());
}

TEST(Procinfo, ReadsKeysFromAProcFile) {
  EXPECT_TRUE(proc_kib("/proc/self/status", "VmRSS").has_value());
  EXPECT_FALSE(proc_kib("/proc/self/status", "NoSuchKey").has_value());
  EXPECT_GT(memory_snapshot().rss_kib, 0);
}

// ---- small runs of the workloads in each model -----------------------------------------------------------------

class EveryModel : public ::testing::TestWithParam<Variant> {};

TEST_P(EveryModel, ParkedTasksAllArriveAndWake) {
  ParkedParams p;
  p.tasks = 60;
  p.wait = 60ms;
  const auto run = run_parked(GetParam(), p);
  ASSERT_TRUE(run.has_value()) << run.error();
  EXPECT_EQ(run->samples.size(), 60U);
  EXPECT_EQ(run->counters.at("tasks_armed"), 60);
  EXPECT_GE(run->counters.at("rss_parked_kib"), 1);
  if (GetParam() == Variant::coroutine) EXPECT_EQ(run->counters.at("frame_allocations"), 60);
}

TEST_P(EveryModel, PingPongServesEveryRoundTripAndKeepsThePayload) {
  PingPongParams p;
  p.rounds = 2000;
  p.batch = 100;
  p.warmup_batches = 2;
  const auto run = run_pingpong(GetParam(), p);
  ASSERT_TRUE(run.has_value()) << run.error();
  EXPECT_EQ(run->samples.size(), 20U);
  EXPECT_EQ(run->counters.at("round_trips_served"), 2000 + 200);
  EXPECT_EQ(run->counters.at("payload_mismatch"), 0);
}

TEST_P(EveryModel, NeighboursWakeEveryIteration) {
  NeighbourParams p;
  p.tasks = 20;
  p.iterations = 10;
  p.period = 1000us;
  const auto run = run_neighbours(GetParam(), p);
  ASSERT_TRUE(run.has_value()) << run.error();
  EXPECT_EQ(run->samples.size(), 200U);
  EXPECT_EQ(run->counters.at("late_starts"), 0);
  EXPECT_EQ(run->counters.at("blocking_calls"), 0);
}

INSTANTIATE_TEST_SUITE_P(Models, EveryModel, ::testing::Values(Variant::os_thread, Variant::fiber, Variant::coroutine),
                         [](const auto& info) { return std::string{name_of(info.param) == "os-thread" ? "OsThread" : info.param == Variant::fiber ? "Fiber" : "Coroutine"}; });

TEST(Neighbours, ABlockingCallInAFiberDelaysItsNeighbours) {
  NeighbourParams p;
  p.tasks = 50;
  p.iterations = 20;
  p.period = 2000us;
  p.blocking_call = true;
  const auto run = run_neighbours(Variant::fiber, p);
  ASSERT_TRUE(run.has_value()) << run.error();
  EXPECT_EQ(run->counters.at("blocking_calls"), 2);
  // The two blocking calls last 2 ms each; the fibers due meanwhile wait for them, so some wake at least 1 ms late.
  const auto late = std::ranges::count_if(run->samples, [](std::int64_t ns) { return ns >= 1'000'000; });
  EXPECT_GT(late, 0);
}

TEST(Neighbours, TheBlockingCallIsDefinedForFibersOnly) {
  NeighbourParams p;
  p.blocking_call = true;
  EXPECT_FALSE(run_neighbours(Variant::coroutine, p).has_value());
}

TEST(Variants, NamesRoundTrip) {
  for (const Variant v : {Variant::os_thread, Variant::fiber, Variant::coroutine}) EXPECT_EQ(parse_variant(name_of(v)), v);
  EXPECT_FALSE(parse_variant("thread").has_value());
}

}  // namespace
}  // namespace lowlat::tasks
