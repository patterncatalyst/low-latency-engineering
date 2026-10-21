// Google Benchmark: the optimizer trap and how a harness avoids it.
//
//   BM_CheckDigit_Guarded    inputs come from a vector the compiler cannot see through;
//                            every result goes through benchmark::DoNotOptimize.
//   BM_CheckDigit_Eliminated constant input, result discarded: the check digit is a pure
//                            function, so the optimizer folds it and the loop times nothing.
//
// Each benchmark runs 30 repetitions. Google Benchmark's aggregates default to mean,
// median, stddev and cv; the median is the one to read, and the "p99" statistic added
// below is the worst-tail view across repetitions. Never quote the mean.
#include <benchmark/benchmark.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <string>
#include <vector>

#include "check_digit.hpp"
#include "prefixes.hpp"

namespace {

using lowlat::bench::check_digit;

constexpr std::size_t kPrefixCount = 1024;  // power of two: index with a mask
constexpr int kRepetitions = 30;

// Nearest-rank percentile over the per-repetition values.
double p99(const std::vector<double>& values) {
  std::vector<double> sorted(values);
  std::ranges::sort(sorted);
  const auto rank = static_cast<std::size_t>(std::ceil(0.99 * static_cast<double>(sorted.size())));
  return sorted[rank - 1];
}

void BM_CheckDigit_Guarded(benchmark::State& state) {
  // Built at run time and escaped, so the compiler knows neither the values nor the size.
  std::vector<std::string> prefixes = lowlat::bench::make_prefixes(kPrefixCount);
  benchmark::DoNotOptimize(prefixes.data());
  std::size_t i = 0;
  for (auto _ : state) {
    const int digit = check_digit(prefixes[i++ & (kPrefixCount - 1)]);
    benchmark::DoNotOptimize(digit);
    benchmark::ClobberMemory();  // force pending writes out; nothing may be reordered past here
  }
}

void BM_CheckDigit_Eliminated(benchmark::State& state) {
  // Constant input, result thrown away: nothing observable depends on the work.
  for (auto _ : state) {
    (void)check_digit("00614141000000007");
  }
}

}  // namespace

BENCHMARK(BM_CheckDigit_Guarded)
    ->Repetitions(kRepetitions)
    ->MinTime(0.1)
    ->ComputeStatistics("p99", p99);
BENCHMARK(BM_CheckDigit_Eliminated)
    ->Repetitions(kRepetitions)
    ->MinTime(0.1)
    ->ComputeStatistics("p99", p99);

BENCHMARK_MAIN();
