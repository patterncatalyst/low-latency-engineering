// Google Benchmark: what one decision costs in heap allocations, C++ side.
//
//   BM_Decide_Value       the Decision is a value on the stack. The C++ default.
//   BM_Decide_Allocating  the same Decision behind a std::make_unique: one `new` per parcel, the
//                         allocation the JVM's escape analysis would have removed.
//   BM_Decide_Pmr         observed: the same heap object, but from a std::pmr::monotonic_buffer_resource
//                         over a stack buffer. No call to the global allocator; the arena is rewound in bulk.
//
// The global operator new is replaced to count calls and bytes. Each benchmark reports allocs/op and
// B/op as counters, which are exact, next to the timing repetitions. Never quote the mean.
#include <benchmark/benchmark.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <memory_resource>
#include <new>
#include <random>
#include <vector>

#include "lowlat/jvmcosts/tracker.hpp"

namespace {

std::atomic<std::uint64_t> g_allocations{0};
std::atomic<std::uint64_t> g_bytes{0};

}  // namespace

// Replaceable allocation functions: count, then defer to malloc. GCC 16 cannot see that operator
// new is malloc-backed in this translation unit and reports the free() in the matching operator
// delete as a mismatch (-Wmismatched-new-delete); the pair is consistent.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmismatched-new-delete"
void* operator new(std::size_t size) {
  g_allocations.fetch_add(1, std::memory_order_relaxed);
  g_bytes.fetch_add(size, std::memory_order_relaxed);
  if (void* p = std::malloc(size)) return p;
  throw std::bad_alloc{};
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
#pragma GCC diagnostic pop

namespace {

namespace jvmcosts = lowlat::jvmcosts;
namespace v1 = lowlat::line::v1;

constexpr std::size_t kParcels = 1024;  // power of two: index with a mask
constexpr int kRepetitions = 30;
constexpr std::size_t kArenaBytes = 64 * 1024;
constexpr std::size_t kRewindEvery = 2048;  // 2048 x 16 B = 32 KiB, half the arena

// Parcels shaped like the simulator's, built before main() so no benchmark counts their allocation.
std::vector<v1::ParcelEvent> make_parcels() {
  std::mt19937_64 rng{42};
  std::lognormal_distribution<double> weight{std::log(2000.0), 0.6};
  std::vector<v1::ParcelEvent> parcels(kParcels);
  for (std::size_t i = 0; i < kParcels; ++i) {
    auto& ev = parcels[i];
    ev.set_seq(i);
    ev.set_encoder_tick(i * 2);
    ev.set_weight_g(static_cast<std::uint32_t>(std::min(weight(rng), 60'000.0)));
    ev.mutable_dims()->set_length_mm(150 + static_cast<std::uint32_t>(rng() % 1050));
    ev.mutable_dims()->set_width_mm(100 + static_cast<std::uint32_t>(rng() % 600));
    ev.mutable_dims()->set_height_mm(50 + static_cast<std::uint32_t>(rng() % 450));
    ev.set_scan_confidence_permille(rng() % 100 < 97 ? 950 + static_cast<std::uint32_t>(rng() % 51)
                                                     : 300 + static_cast<std::uint32_t>(rng() % 401));
  }
  return parcels;
}

const std::vector<v1::ParcelEvent> kEvents = make_parcels();

// Reports the global allocator's calls and bytes since `start`, per iteration.
class AllocationCounter {
 public:
  AllocationCounter() : allocations_(g_allocations.load()), bytes_(g_bytes.load()) {}

  void report(benchmark::State& state) const {
    const auto per_iteration = benchmark::Counter::kAvgIterations;
    state.counters["allocs/op"] = benchmark::Counter(static_cast<double>(g_allocations.load() - allocations_), per_iteration);
    state.counters["B/op"] = benchmark::Counter(static_cast<double>(g_bytes.load() - bytes_), per_iteration);
  }

 private:
  std::uint64_t allocations_;
  std::uint64_t bytes_;
};

void BM_Decide_Value(benchmark::State& state) {
  std::size_t i = 0;
  const AllocationCounter counter;
  for (auto _ : state) {
    jvmcosts::Decision decision = jvmcosts::decide(kEvents[i++ & (kParcels - 1)]);
    benchmark::DoNotOptimize(decision);
  }
  counter.report(state);
}

void BM_Decide_Allocating(benchmark::State& state) {
  std::size_t i = 0;
  const AllocationCounter counter;
  for (auto _ : state) {
    auto decision = std::make_unique<jvmcosts::Decision>(jvmcosts::decide(kEvents[i++ & (kParcels - 1)]));
    benchmark::DoNotOptimize(decision);  // the pointer escapes: the allocation cannot be elided
  }
  counter.report(state);
}

void BM_Decide_Pmr(benchmark::State& state) {
  alignas(std::max_align_t) std::array<std::byte, kArenaBytes> buffer;
  // The null resource upstream: running out of arena would throw instead of reaching the global allocator.
  std::pmr::monotonic_buffer_resource arena{buffer.data(), buffer.size(), std::pmr::null_memory_resource()};
  std::pmr::polymorphic_allocator<jvmcosts::Decision> allocator{&arena};
  std::size_t i = 0;
  const AllocationCounter counter;
  for (auto _ : state) {
    jvmcosts::Decision* decision = allocator.new_object<jvmcosts::Decision>(jvmcosts::decide(kEvents[i & (kParcels - 1)]));
    benchmark::DoNotOptimize(decision);
    if (++i % kRewindEvery == 0) arena.release();  // the whole arena in one step; no per-object free
  }
  counter.report(state);
}

}  // namespace

BENCHMARK(BM_Decide_Value)->Repetitions(kRepetitions)->MinTime(0.1);
BENCHMARK(BM_Decide_Allocating)->Repetitions(kRepetitions)->MinTime(0.1);
BENCHMARK(BM_Decide_Pmr)->Repetitions(kRepetitions)->MinTime(0.1);

BENCHMARK_MAIN();
