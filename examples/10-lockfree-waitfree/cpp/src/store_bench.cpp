// Per-store cost of the two memory orders in the induction-gap test (observed, not asserted).
//
// A release store is a plain mov on x86-64; a seq_cst store is xchg, which also drains the store
// buffer. Each benchmark stores an incrementing value to one atomic with external linkage, so the
// compiler cannot prove that nobody reads it and delete the stores (a local atomic that never
// escapes is removed at -O2: the loop then measures an empty loop). Run it on one pinned CPU (taskset)
// so that the cost is the instruction's, not a migration's.
#include <benchmark/benchmark.h>

#include <atomic>
#include <cstdint>

// Namespace scope, outside the anonymous namespace: another translation unit could read it.
std::atomic<std::uint64_t> g_store_target{0};

namespace {

template <std::memory_order Order>
void store(benchmark::State& state) {
  std::uint64_t i = 0;
  for (auto _ : state) {
    g_store_target.store(++i, Order);
    benchmark::ClobberMemory();
  }
}

void BM_ReleaseAcquire(benchmark::State& state) { store<std::memory_order_release>(state); }
void BM_SeqCst(benchmark::State& state) { store<std::memory_order_seq_cst>(state); }

}  // namespace

BENCHMARK(BM_ReleaseAcquire)->Repetitions(30)->MinTime(0.1);
BENCHMARK(BM_SeqCst)->Repetitions(30)->MinTime(0.1);

BENCHMARK_MAIN();
