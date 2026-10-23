// Per-store cost of the two memory orders in the induction-gap test (observed, not asserted).
//
// A release store is a plain mov on x86-64; a seq_cst store is xchg, which also drains the store
// buffer. Each benchmark stores an incrementing value to one atomic, so the compiler cannot fold the
// stores away. Run it on one pinned CPU (taskset) so that the cost is the instruction's, not a
// migration's.
#include <benchmark/benchmark.h>

#include <atomic>
#include <cstdint>

namespace {

template <std::memory_order Order>
void store(benchmark::State& state) {
  std::atomic<std::uint64_t> flag{0};
  std::uint64_t i = 0;
  for (auto _ : state) {
    flag.store(++i, Order);
    benchmark::ClobberMemory();
  }
}

void BM_ReleaseAcquire(benchmark::State& state) { store<std::memory_order_release>(state); }
void BM_SeqCst(benchmark::State& state) { store<std::memory_order_seq_cst>(state); }

}  // namespace

BENCHMARK(BM_ReleaseAcquire)->Repetitions(30)->MinTime(0.1);
BENCHMARK(BM_SeqCst)->Repetitions(30)->MinTime(0.1);

BENCHMARK_MAIN();
