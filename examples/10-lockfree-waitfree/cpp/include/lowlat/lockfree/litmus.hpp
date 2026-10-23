// The induction-gap test (the store-buffer litmus test).
//
// Two induction stations each raise "I am claiming the gap" (a store) and then look at the other
// station's flag (a load):
//
//   station A:  a.store(1); r1 = b.load()        station B:  b.store(1); r2 = a.load()
//
// If both read 0, neither saw the other's claim and both induct into the one gap. Each store waits
// in its core's store buffer while the same core's load runs ahead, so release/acquire allows
// r1 == r2 == 0 (on x86-64 these are plain mov instructions). memory_order_seq_cst forbids it: the
// seq_cst store compiles to xchg, which drains the store buffer first.
//
// Every trial runs on two threads pinned to distinct cores and is lined up by a spin barrier, so the
// two bodies overlap closely. The flags are reset between trials by the thread that owns them,
// after both threads have finished the body, and every result is written by its own thread into
// its own array and read after join(), so the harness has no data race of its own.
#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "lowlat/lockfree/claim_log.hpp"
#include "lowlat/lockfree/placement.hpp"

namespace lowlat::lockfree {

struct LitmusCounts {
  std::uint64_t trials = 0;
  std::uint64_t r1_0_r2_0 = 0;  ///< the outcome release/acquire allows and seq_cst forbids
  std::uint64_t r1_0_r2_1 = 0;
  std::uint64_t r1_1_r2_0 = 0;
  std::uint64_t r1_1_r2_1 = 0;
};

/// Calls `batch_done(ns_per_trial)` from station A after every `batch` trials: the run's cost
/// distribution. Pinning is skipped for a CPU of -1 (the unit test).
template <std::memory_order StoreOrder, std::memory_order LoadOrder>
LitmusCounts run_litmus(std::uint64_t trials, int cpu_a, int cpu_b, std::uint64_t batch, Gate& gate,
                        const std::function<void(std::int64_t)>& batch_done) {
  struct alignas(2 * std::hardware_destructive_interference_size) Flag {
    std::atomic<std::uint64_t> value{0};
  };
  Flag flag_a, flag_b;     // the litmus variables
  Flag step_a, step_b;     // the spin barrier: each station publishes how far it has got
  std::vector<std::uint8_t> r1(trials), r2(trials);

  const auto station = [&](int cpu, std::string role, Flag& mine, Flag& theirs, Flag& my_step, Flag& their_step,
                           std::vector<std::uint8_t>& result, bool times_batches) {
    gate.worker_ready(cpu, std::move(role));
    std::int64_t batch_start = line::monotonic_ns();
    for (std::uint64_t i = 0; i < trials; ++i) {
      const std::uint64_t arrive = 2 * i + 1, leave = 2 * i + 2;
      my_step.value.store(arrive, std::memory_order_release);
      while (their_step.value.load(std::memory_order_acquire) < arrive) cpu_relax();

      mine.value.store(1, StoreOrder);
      result[i] = static_cast<std::uint8_t>(theirs.value.load(LoadOrder));

      my_step.value.store(leave, std::memory_order_release);
      while (their_step.value.load(std::memory_order_acquire) < leave) cpu_relax();
      mine.value.store(0, std::memory_order_relaxed);  // both bodies are over; the next arrive publishes this

      if (times_batches && (i + 1) % batch == 0) {
        const std::int64_t now = line::monotonic_ns();
        batch_done((now - batch_start) / static_cast<std::int64_t>(batch));
        batch_start = now;
      }
    }
  };

  {
    std::jthread a{station, cpu_a, std::string{"station-a"}, std::ref(flag_a), std::ref(flag_b), std::ref(step_a),
                   std::ref(step_b), std::ref(r1), true};
    std::jthread b{station, cpu_b, std::string{"station-b"}, std::ref(flag_b), std::ref(flag_a), std::ref(step_b),
                   std::ref(step_a), std::ref(r2), false};
    gate.release();
  }  // join: the result arrays are now safe to read

  LitmusCounts counts;
  counts.trials = trials;
  for (std::uint64_t i = 0; i < trials; ++i) {
    if (r1[i] == 0 && r2[i] == 0) ++counts.r1_0_r2_0;
    else if (r1[i] == 0) ++counts.r1_0_r2_1;
    else if (r2[i] == 0) ++counts.r1_1_r2_0;
    else ++counts.r1_1_r2_1;
  }
  return counts;
}

}  // namespace lowlat::lockfree
