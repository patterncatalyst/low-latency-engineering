// Deterministic checks only: exactly-once claims, no torn snapshot, no forbidden litmus outcome.
// The allowed litmus outcome (release/acquire both-zero) depends on the hardware and the schedule,
// so it is measured by verify.sh, never asserted here.
#include <gtest/gtest.h>
#include <sched.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "lowlat/lockfree/claim.hpp"
#include "lowlat/lockfree/claim_log.hpp"
#include "lowlat/lockfree/litmus.hpp"
#include "lowlat/lockfree/options.hpp"
#include "lowlat/lockfree/placement.hpp"
#include "lowlat/lockfree/seqlock.hpp"

namespace lf = lowlat::lockfree;

namespace {

struct Outcome {
  std::uint64_t distinct = 0;
  std::uint64_t mismatches = 0;
  lf::ClaimStats total;
};

// Four producers claim `per_thread` slots each into a log far smaller than the claim count, one
// consumer reads them in order. Each producer writes its claimed bit; the sum is checked after join.
template <lf::SequenceClaim Claim>
Outcome claim_all(std::uint64_t per_thread) {
  constexpr std::size_t kProducers = 4;
  const std::uint64_t total = kProducers * per_thread;
  lf::ClaimLog<Claim, std::uint64_t> log{256};
  std::vector<std::uint8_t> claimed(total);
  std::vector<lf::ClaimStats> stats(kProducers);
  std::uint64_t mismatches = 0;
  {
    std::vector<std::jthread> threads;
    for (std::size_t k = 0; k < kProducers; ++k) {
      threads.emplace_back([&, k] {
        for (std::uint64_t i = 0; i < per_thread; ++i) {
          const std::uint64_t seq = log.claim(stats[k]);
          claimed[seq] = 1;
          log.publish(seq, seq ^ 0xabcdU, stats[k]);
        }
      });
    }
    threads.emplace_back([&] {
      for (std::uint64_t seq = 0; seq < total; ++seq) {
        std::int64_t waited = 0;
        if (log.read(seq, waited) != (seq ^ 0xabcdU)) ++mismatches;
        log.consumed(seq);
      }
    });
  }
  Outcome out;
  out.distinct = std::accumulate(claimed.begin(), claimed.end(), std::uint64_t{0});
  out.mismatches = mismatches;
  for (const auto& s : stats) {
    out.total.claims += s.claims;
    out.total.steps += s.steps;
    out.total.cas_failures += s.cas_failures;
  }
  return out;
}

}  // namespace

TEST(Claims, EveryVariantHandsOutEachSequenceExactlyOnce) {
  constexpr std::uint64_t kPerThread = 20'000;
  for (const auto& out : {claim_all<lf::MutexClaim>(kPerThread), claim_all<lf::CasLoopClaim>(kPerThread),
                          claim_all<lf::FetchAddClaim>(kPerThread)}) {
    EXPECT_EQ(out.total.claims, 4 * kPerThread);
    EXPECT_EQ(out.distinct, 4 * kPerThread);
    EXPECT_EQ(out.mismatches, 0U);
  }
}

TEST(Claims, FetchAddIsOneStepPerClaim) {
  const Outcome out = claim_all<lf::FetchAddClaim>(10'000);
  EXPECT_EQ(out.total.steps, out.total.claims);
  EXPECT_EQ(out.total.cas_failures, 0U);
}

TEST(Claims, CasLoopCountsItsFailedAttempts) {
  const Outcome out = claim_all<lf::CasLoopClaim>(10'000);
  EXPECT_EQ(out.total.steps, out.total.claims + out.total.cas_failures);
}

TEST(Seqlock, ReadersNeverSeeATornSnapshot) {
  lf::Seqlock cell;
  std::atomic<std::uint64_t> torn{0}, reads{0};
  {
    std::vector<std::jthread> threads;
    threads.emplace_back([&](std::stop_token stop) {
      for (std::uint64_t n = 1; !stop.stop_requested(); ++n) cell.write(lf::ParcelSnapshot::of(n));
    });
    for (int r = 0; r < 3; ++r) {
      threads.emplace_back([&](std::stop_token stop) {
        std::uint64_t retries = 0;
        while (!stop.stop_requested()) {
          if (!cell.read(retries).consistent()) torn.fetch_add(1, std::memory_order_relaxed);
          reads.fetch_add(1, std::memory_order_relaxed);
        }
      });
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{300});
    for (auto& t : threads) t.request_stop();
  }
  EXPECT_EQ(torn.load(), 0U);
  EXPECT_GT(reads.load(), 0U);
}

// Negative control: the seqlock's read with the validation removed (no sequence check before or after
// the copy) while the writer stores the same words the same way. If a reader of this cell never tore,
// "zero torn reads" above would prove nothing. Loops until a tear is seen, bounded by a deadline.
namespace {
class UncheckedCell {
 public:
  void write(const lf::ParcelSnapshot& s) noexcept {
    for (std::size_t i = 0; i < lf::ParcelSnapshot::kWords; ++i) {
      std::atomic_ref<std::uint64_t>{words_[i]}.store(s.word[i], std::memory_order_relaxed);
    }
  }
  [[nodiscard]] lf::ParcelSnapshot read() const noexcept {
    lf::ParcelSnapshot s;
    for (std::size_t i = 0; i < lf::ParcelSnapshot::kWords; ++i) {
      s.word[i] = std::atomic_ref<std::uint64_t>{words_[i]}.load(std::memory_order_relaxed);
    }
    return s;
  }

 private:
  alignas(std::atomic_ref<std::uint64_t>::required_alignment) mutable std::array<std::uint64_t, lf::ParcelSnapshot::kWords> words_{};
};
}  // namespace

TEST(Seqlock, NegativeControlWithoutValidationReadsTornSnapshots) {
  cpu_set_t allowed;
  CPU_ZERO(&allowed);
  if (sched_getaffinity(0, sizeof allowed, &allowed) != 0 || CPU_COUNT(&allowed) < 2) GTEST_SKIP() << "a torn read needs the writer and the reader on different CPUs";
  UncheckedCell cell;
  cell.write(lf::ParcelSnapshot::of(0));
  std::atomic<bool> stop{false};
  std::uint64_t torn = 0;
  {
    std::jthread writer{[&] {
      for (std::uint64_t n = 1; !stop.load(std::memory_order_relaxed); ++n) cell.write(lf::ParcelSnapshot::of(n));
    }};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{20};
    while (torn == 0 && std::chrono::steady_clock::now() < deadline) {
      for (int i = 0; i < 100'000 && torn == 0; ++i) {
        if (!cell.read().consistent()) ++torn;
      }
    }
    stop.store(true, std::memory_order_relaxed);
  }
  EXPECT_GT(torn, 0U) << "no torn read in 20 s: the checksum cannot detect tearing, so the zero above proves nothing";
}

TEST(Seqlock, ASnapshotWithMixedWordsFailsItsChecksum) {
  lf::ParcelSnapshot a = lf::ParcelSnapshot::of(1);
  const lf::ParcelSnapshot b = lf::ParcelSnapshot::of(2);
  EXPECT_TRUE(a.consistent());
  a.word[3] = b.word[3];
  EXPECT_FALSE(a.consistent());
}

TEST(Litmus, SeqCstForbidsBothZero) {
  lf::Gate gate{2, std::chrono::milliseconds{0}};
  std::uint64_t batches = 0;
  const lf::LitmusCounts c = lf::run_litmus<std::memory_order_seq_cst, std::memory_order_seq_cst>(
      200'000, -1, -1, 1000, gate, [&](std::int64_t) { ++batches; });
  EXPECT_EQ(c.r1_0_r2_0, 0U);
  EXPECT_EQ(c.r1_0_r2_0 + c.r1_0_r2_1 + c.r1_1_r2_0 + c.r1_1_r2_1, c.trials);
  EXPECT_EQ(batches, 200U);
}

TEST(Litmus, ReleaseAcquireCountsEveryTrial) {
  lf::Gate gate{2, std::chrono::milliseconds{0}};
  const lf::LitmusCounts c = lf::run_litmus<std::memory_order_release, std::memory_order_acquire>(
      50'000, -1, -1, 1000, gate, [](std::int64_t) {});
  EXPECT_EQ(c.r1_0_r2_0 + c.r1_0_r2_1 + c.r1_1_r2_0 + c.r1_1_r2_1, c.trials);
}

TEST(Options, NumbersAreParsedWhole) {
  char prog[] = "prog", key[] = "--count", good[] = "42";
  char* ok_argv[] = {prog, key, good};
  EXPECT_EQ((lf::Options{3, ok_argv, 1}.number("count", 7)), 42U);
  EXPECT_EQ((lf::Options{1, ok_argv, 1}.number("count", 7)), 7U);  // absent: the fallback

  for (const char* bad : {"12abc", "-1", "", "1.5"}) {
    std::string text{bad};
    char* argv[] = {prog, key, text.data()};
    const lf::Options o{3, argv, 1};
    EXPECT_THROW((void)o.number("count", 7), std::invalid_argument) << "'" << bad << "'";
  }
}

TEST(Options, FlagsTakeNoValueAndOptionsNeedOne) {
  char prog[] = "prog", flag[] = "--stalled-producer", key[] = "--cpus";
  char* with_flag[] = {prog, flag};
  EXPECT_TRUE((lf::Options{2, with_flag, 1, {"stalled-producer"}}.flag("stalled-producer")));
  EXPECT_THROW((lf::Options{2, with_flag, 1}), std::invalid_argument);  // not declared a flag: needs a value
  char* missing[] = {prog, key};
  EXPECT_THROW((lf::Options{2, missing, 1}), std::invalid_argument);
}

TEST(Placement, CpuListParses) {
  EXPECT_EQ(lf::parse_cpu_list("0,2,4"), (std::vector<int>{0, 2, 4}));
  EXPECT_THROW((void)lf::parse_cpu_list("0,x"), std::invalid_argument);
  EXPECT_THROW((void)lf::parse_cpu_list(""), std::invalid_argument);
}

TEST(Placement, PinnedThreadRunsOnItsCpu) {
  const std::vector<int> allowed = [] {
    std::vector<int> out;
    cpu_set_t set;
    CPU_ZERO(&set);
    sched_getaffinity(0, sizeof set, &set);
    for (int c = 0; c < CPU_SETSIZE; ++c) {
      if (CPU_ISSET(c, &set)) out.push_back(c);
    }
    return out;
  }();
  ASSERT_FALSE(allowed.empty());
  std::thread t{[&] { EXPECT_NO_THROW(lf::pin_current_thread(allowed.front())); }};
  t.join();
}
