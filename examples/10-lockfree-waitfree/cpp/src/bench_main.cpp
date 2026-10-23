// lockfree-bench: the Ch10 microbenchmarks in C++ (see ../README.md).
//
//   lockfree-bench claim   --variant mutex|cas-loop|fetch-add [--stalled-producer]
//   lockfree-bench litmus  --variant release-acquire|seq-cst
//   lockfree-bench seqlock --variant shared-mutex|seqlock
//
// Every run pins its threads to the CPUs of --cpus (distinct physical cores), prints one
// "pinned ..." line per thread and "placement-ready", holds for --hold-ms so that a script can check
// each thread's CPU in /proc, and then measures. Latencies go into HdrHistogram reports, exact event
// counts into runtime.counters.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <concepts>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <format>
#include <map>
#include <memory>
#include <numeric>
#include <print>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "lowlat/line/clock.hpp"
#include "lowlat/line/consumer.hpp"
#include "lowlat/lockfree/claim.hpp"
#include "lowlat/lockfree/claim_log.hpp"
#include "lowlat/lockfree/litmus.hpp"
#include "lowlat/lockfree/options.hpp"
#include "lowlat/lockfree/placement.hpp"
#include "lowlat/lockfree/report_util.hpp"
#include "lowlat/lockfree/seqlock.hpp"
#include "lowlat/measure/recorder.hpp"
#include "lowlat/measure/runtime.hpp"

namespace {

namespace lf = lowlat::lockfree;
namespace measure = lowlat::measure;
using lowlat::line::monotonic_ns;
using namespace std::chrono_literals;

constexpr std::string_view kExample = "10-lockfree-waitfree";
constexpr std::uint64_t kPayloadStride = 0x9e3779b97f4a7c15ULL;  // slot payload = seq * stride

// --- options ------------------------------------------------------------------------------------

using lf::Options;

std::vector<int> cpus_for(const Options& o, std::size_t needed) {
  const std::string list = o.text("cpus", "");
  if (list.empty()) return std::vector<int>(needed, -1);  // unpinned: unit tests and quick looks
  auto cpus = lf::parse_cpu_list(list);
  if (cpus.size() < needed) throw std::invalid_argument(std::format("--cpus needs {} CPUs, got {}", needed, cpus.size()));
  cpus.resize(needed);
  return cpus;
}

nlohmann::json placement_block(const std::vector<int>& cpus) {
  std::vector<int> pinned;
  for (const int c : cpus) {
    if (c >= 0) pinned.push_back(c);
  }
  return pinned.empty() ? nlohmann::json::object() : lf::placement_of(pinned);
}

void write(const measure::Recorder& r, const Options& o, std::string_view suffix, const std::string& notes,
           const nlohmann::json& runtime) {
  r.print_summary();
  const std::string path = o.text("report", "");
  if (path.empty()) return;
  const auto target = suffix.empty() ? std::filesystem::path{path} : lowlat::line::report_sibling(path, suffix);
  r.write_report(target, notes, std::nullopt, runtime);
  std::println("report: {}", target.string());
}

// --- claim --------------------------------------------------------------------------------------

struct ClaimThreadResult {
  lf::CtxSwitches ctx;
};

template <lf::SequenceClaim Claim>
int run_claim(const Options& o, const std::string& variant) {
  const std::size_t producers = o.number("producers", 4);
  const std::uint64_t per_thread = o.number("claims-per-thread", 1'000'000);
  const std::uint64_t total = producers * per_thread;
  const std::size_t capacity = o.number("capacity", 1U << 20);
  const bool stalled = o.flag("stalled-producer");
  const std::uint64_t stalled_seq = o.number("stalled-seq", total / 2);
  const auto cpus = cpus_for(o, producers + 1);
  lf::Gate gate{static_cast<std::ptrdiff_t>(producers + 1), std::chrono::milliseconds{o.number("hold-ms", 0)}};

  lf::ClaimLog<Claim, std::uint64_t> log{capacity};
  std::vector<std::uint8_t> claimed(total);  // claimed[seq] = 1, written by whoever claimed seq
  std::vector<lf::ClaimStats> stats(producers);
  std::vector<measure::Recorder> claim_ns;
  std::vector<lf::CtxSwitches> ctx(producers);
  for (std::size_t k = 0; k < producers; ++k) claim_ns.emplace_back(std::string{kExample}, variant);
  measure::Recorder consumer_wait{std::string{kExample}, variant};
  std::uint64_t payload_mismatches = 0, consumer_max_wait_ns = 0, consumer_wait_at_stalled_ns = 0;  // consumer thread only until join

  {
    std::vector<std::jthread> threads;
    threads.reserve(producers + 1);
    for (std::size_t k = 0; k < producers; ++k) {
      threads.emplace_back([&, k] {
        gate.worker_ready(cpus[k], std::format("producer-{}", k));
        const lf::CtxSwitches before = lf::thread_ctx_switches();
        lf::ClaimStats& mine = stats[k];
        measure::Recorder& rec = claim_ns[k];
        for (std::uint64_t i = 0; i < per_thread; ++i) {
          const std::int64_t t0 = monotonic_ns();
          const std::uint64_t seq = log.claim(mine);
          rec.record(monotonic_ns() - t0);
          if (stalled && seq == stalled_seq) std::this_thread::sleep_for(1ms);  // claimed, not yet published
          claimed[seq] = 1;
          log.publish(seq, seq * kPayloadStride, mine);
        }
        const lf::CtxSwitches after = lf::thread_ctx_switches();
        ctx[k] = {after.voluntary - before.voluntary, after.involuntary - before.involuntary};
      });
    }
    threads.emplace_back([&] {
      gate.worker_ready(cpus[producers], "consumer");
      for (std::uint64_t seq = 0; seq < total; ++seq) {
        std::int64_t waited = 0;
        const std::uint64_t payload = log.read(seq, waited);
        if (payload != seq * kPayloadStride) ++payload_mismatches;
        log.consumed(seq);
        if (waited > 0) {
          consumer_wait.record(waited);
          consumer_max_wait_ns = std::max<std::uint64_t>(consumer_max_wait_ns, static_cast<std::uint64_t>(waited));
          if (seq == stalled_seq) consumer_wait_at_stalled_ns = static_cast<std::uint64_t>(waited);
        }
      }
    });
    gate.release();
  }  // joined: stats, bitmap and the consumer's results are safe to read

  measure::Recorder merged{std::string{kExample}, variant};
  for (const auto& r : claim_ns) lf::merge_into(merged, r);
  std::uint64_t claims = 0, steps = 0, cas_failures = 0, max_retries = 0;
  for (const auto& s : stats) {
    claims += s.claims;
    steps += s.steps;
    cas_failures += s.cas_failures;
    max_retries = std::max(max_retries, s.max_retries);
  }
  const std::uint64_t distinct = std::accumulate(claimed.begin(), claimed.end(), std::uint64_t{0});
  lf::CtxSwitches ctx_total;
  std::int64_t vol_max = 0, vol_min = ctx.empty() ? 0 : ctx.front().voluntary;
  for (const auto& c : ctx) {
    vol_max = std::max(vol_max, c.voluntary);
    vol_min = std::min(vol_min, c.voluntary);
    ctx_total.voluntary += c.voluntary;
    ctx_total.involuntary += c.involuntary;
  }

  nlohmann::json runtime;
  if (const auto p = placement_block(cpus); !p.empty()) runtime["placement"] = p;
  runtime["ctx_switches"] = {{"voluntary", ctx_total.voluntary}, {"involuntary", ctx_total.involuntary}};
  std::map<std::string, std::int64_t> counters{
      {"claims", static_cast<std::int64_t>(claims)},
      {"claim_steps", static_cast<std::int64_t>(steps)},
      {"cas_failures", static_cast<std::int64_t>(cas_failures)},
      {"cas_max_retries", static_cast<std::int64_t>(max_retries)},
      {"lost_or_duplicated_claims", static_cast<std::int64_t>(total - distinct)},
      {"payload_mismatches", static_cast<std::int64_t>(payload_mismatches)},
      {"consumer_max_wait_ns", static_cast<std::int64_t>(consumer_max_wait_ns)},
      {"producer_voluntary_ctx_max", vol_max},  // the most any one producer switched voluntarily
      {"producer_voluntary_ctx_min", vol_min},
  };
  if (stalled) counters["consumer_wait_at_stalled_seq_ns"] = static_cast<std::int64_t>(consumer_wait_at_stalled_ns);
  runtime["counters"] = measure::counters(counters);
  const std::string notes = std::format(
      "claim; producers={}; claims_per_thread={}; log_slots={}; stalled_producer={}; stalled_seq={}; "
      "claim time is clock_gettime around the claim only",
      producers, per_thread, capacity, stalled, stalled ? std::to_string(stalled_seq) : "none");
  write(merged, o, "", notes, runtime);
  if (consumer_wait.count() > 0) {
    nlohmann::json wait_runtime;
    if (runtime.contains("placement")) wait_runtime["placement"] = runtime["placement"];
    write(consumer_wait, o, "-consumer-wait", notes + "; the consumer's waits at claimed-but-unpublished slots", wait_runtime);
  }
  return 0;
}

// --- litmus -------------------------------------------------------------------------------------

template <std::memory_order Store, std::memory_order Load>
int run_litmus_variant(const Options& o, const std::string& variant) {
  const std::uint64_t trials = o.number("trials", 10'000'000);
  const std::uint64_t batch = o.number("batch", 1000);
  const auto cpus = cpus_for(o, 2);
  lf::Gate gate{2, std::chrono::milliseconds{o.number("hold-ms", 0)}};
  measure::Recorder per_trial{std::string{kExample}, variant};
  const lf::LitmusCounts c = lf::run_litmus<Store, Load>(trials, cpus[0], cpus[1], batch, gate,
                                                         [&](std::int64_t ns) { per_trial.record(ns); });
  nlohmann::json runtime;
  if (const auto p = placement_block(cpus); !p.empty()) runtime["placement"] = p;
  runtime["counters"] = measure::counters({{"trials", static_cast<std::int64_t>(c.trials)},
                                           {"outcome_r1_0_r2_0", static_cast<std::int64_t>(c.r1_0_r2_0)},
                                           {"outcome_r1_0_r2_1", static_cast<std::int64_t>(c.r1_0_r2_1)},
                                           {"outcome_r1_1_r2_0", static_cast<std::int64_t>(c.r1_1_r2_0)},
                                           {"outcome_r1_1_r2_1", static_cast<std::int64_t>(c.r1_1_r2_1)}});
  const std::string notes = std::format(
      "litmus (induction-gap test); trials={}; each sample is the wall time per trial averaged over {} trials "
      "(barrier included); both-zero outcome is r1=0 and r2=0",
      trials, batch);
  write(per_trial, o, "", notes, runtime);
  return 0;
}

// --- seqlock ------------------------------------------------------------------------------------

template <class Cell>
int run_cell(const Options& o, const std::string& variant) {
  const std::size_t readers = o.number("readers", 3);
  const auto duration = std::chrono::milliseconds{o.number("duration-ms", 2000)};
  const std::int64_t period_ns = static_cast<std::int64_t>(o.number("update-period-ns", 1000));  // 1 MHz
  const auto cpus = cpus_for(o, readers + 1);
  lf::Gate gate{static_cast<std::ptrdiff_t>(readers + 1), std::chrono::milliseconds{o.number("hold-ms", 0)}};

  Cell cell;
  measure::Recorder update_ns{std::string{kExample}, variant};
  std::uint64_t updates = 0;
  struct alignas(2 * std::hardware_destructive_interference_size) ReaderTotals {
    std::uint64_t reads = 0, torn = 0, retries = 0;
  };
  std::vector<ReaderTotals> totals(readers);

  {
    std::vector<std::jthread> threads;
    threads.reserve(readers + 1);
    threads.emplace_back([&](std::stop_token stop) {
      gate.worker_ready(cpus[0], "writer");
      std::int64_t due = monotonic_ns();
      for (std::uint64_t n = 1; !stop.stop_requested(); ++n) {
        due += period_ns;
        while (monotonic_ns() < due) lf::cpu_relax();  // open loop: a late update is not skipped
        const lf::ParcelSnapshot snapshot = lf::ParcelSnapshot::of(n);
        const std::int64_t t0 = monotonic_ns();
        cell.write(snapshot);
        update_ns.record(monotonic_ns() - t0);
        ++updates;
      }
    });
    for (std::size_t r = 0; r < readers; ++r) {
      threads.emplace_back([&, r](std::stop_token stop) {
        gate.worker_ready(cpus[r + 1], std::format("reader-{}", r));
        ReaderTotals& mine = totals[r];
        while (!stop.stop_requested()) {
          lf::ParcelSnapshot s;
          if constexpr (std::same_as<Cell, lf::Seqlock>) {
            s = cell.read(mine.retries);
          } else {
            s = cell.read();
          }
          ++mine.reads;
          if (!s.consistent()) ++mine.torn;
        }
      });
    }
    gate.release();
    std::this_thread::sleep_for(duration);
    for (auto& t : threads) t.request_stop();
  }  // joined

  ReaderTotals sum;
  for (const auto& t : totals) {
    sum.reads += t.reads;
    sum.torn += t.torn;
    sum.retries += t.retries;
  }
  nlohmann::json runtime;
  if (const auto p = placement_block(cpus); !p.empty()) runtime["placement"] = p;
  runtime["counters"] = measure::counters({{"updates", static_cast<std::int64_t>(updates)},
                                           {"reads", static_cast<std::int64_t>(sum.reads)},
                                           {"torn_snapshots", static_cast<std::int64_t>(sum.torn)},
                                           {"reader_retries", static_cast<std::int64_t>(sum.retries)}});
  const std::string notes = std::format(
      "seqlock; one writer at {} ns period (open loop), {} readers spinning, {} ms; a snapshot is {} words with a checksum; "
      "update time is clock_gettime around write() only",
      period_ns, readers, duration.count(), lf::ParcelSnapshot::kWords);
  write(update_ns, o, "", notes, runtime);
  return 0;
}

int dispatch(int argc, char** argv) {
  if (argc < 2) throw std::invalid_argument("usage: lockfree-bench claim|litmus|seqlock --variant NAME [options]");
  const std::string_view command{argv[1]};
  const Options o{argc, argv, 2, {"stalled-producer"}};
  const std::string variant = o.text("variant", "");
  if (command == "claim") {
    if (variant == "mutex") return run_claim<lf::MutexClaim>(o, variant);
    if (variant == "cas-loop") return run_claim<lf::CasLoopClaim>(o, variant);
    if (variant == "fetch-add") return run_claim<lf::FetchAddClaim>(o, variant);
    throw std::invalid_argument("--variant: mutex | cas-loop | fetch-add");
  }
  if (command == "litmus") {
    if (variant == "release-acquire") {
      return run_litmus_variant<std::memory_order_release, std::memory_order_acquire>(o, variant);
    }
    if (variant == "seq-cst") return run_litmus_variant<std::memory_order_seq_cst, std::memory_order_seq_cst>(o, variant);
    throw std::invalid_argument("--variant: release-acquire | seq-cst");
  }
  if (command == "seqlock") {
    if (variant == "shared-mutex") return run_cell<lf::SharedMutexCell>(o, variant);
    if (variant == "seqlock") return run_cell<lf::Seqlock>(o, variant);
    throw std::invalid_argument("--variant: shared-mutex | seqlock");
  }
  throw std::invalid_argument(std::format("unknown command '{}'", command));
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return dispatch(argc, argv);
  } catch (const std::exception& e) {
    std::println(stderr, "lockfree-bench: {}", e.what());
    return EXIT_FAILURE;
  }
}
