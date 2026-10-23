// Google Benchmark for the C++ lane of Ch8, an inline contrast to the JVM lane:
//
//   BM_DecodeMemcpy / BM_DecodeBitCast / BM_DecodeStartLifetimeAs
//       Decode one parcel-v1 record from a received buffer (std::span<const std::byte>) and read
//       the fields the line needs. One iteration decodes a batch of 1024 records, so the sample is
//       far above the clock's resolution; divide by `ops_per_iteration` for a per-record time.
//   BM_FlatTable / BM_PointerTable
//       The encoder-tick sweep over 1,000,000 in-flight parcels: std::vector<ParcelState> against
//       a vector of unique_ptr<ParcelState>. One iteration is one sweep.
//
// 30 repetitions for the decodes, 10 for the sweeps; the median across repetitions is the number
// to read, never the mean that Google Benchmark also prints.
#include <benchmark/benchmark.h>

#include <cstddef>
#include <cstdint>
#include <random>
#include <span>
#include <vector>

#include "lowlat/flat/decode.hpp"
#include "lowlat/flat/table.hpp"
#include "lowlat/line/consumer.hpp"

namespace {

namespace flat = lowlat::flat;
namespace p1 = lowlat::flat::parcel_v1;

constexpr std::size_t kBatch = 1024;
constexpr std::size_t kParcels = 1'000'000;

// Back-to-back records in one vector: operator new aligns it to at least 16 bytes, and 80 is a
// multiple of 8, so every record is aligned for Parcel.
const std::vector<std::byte>& wire() {
  static const std::vector<std::byte> bytes = [] {
    std::mt19937_64 rng{2026};
    std::vector<std::byte> out;
    out.reserve(kBatch * p1::kSize);
    for (std::size_t i = 0; i < kBatch; ++i) {
      p1::Parcel p;
      p.seq = i;
      p.weight_g = 100 + static_cast<std::uint32_t>(rng() % 29'900);
      p.length_mm = 100 + static_cast<std::uint32_t>(rng() % 700);
      p.intended_emit_ns = 5'000'000'000'000 + static_cast<std::int64_t>(i) * 100'000;
      for (char& c : p.barcode) c = static_cast<char>('0' + rng() % 10);
      const p1::Bytes record = p1::encode(p);
      out.insert(out.end(), record.begin(), record.end());
    }
    return out;
  }();
  return bytes;
}

// Record `i` of `all`. The caller takes `all` once before its timed loop, so the function-local
// static behind wire() is not consulted per record.
std::span<const std::byte> record(std::span<const std::byte> all, std::size_t i) {
  return all.subspan(i * p1::kSize, p1::kSize);
}

// The fields the line reads, the same in every variant.
std::uint64_t work(const p1::Parcel& p) {
  return p.seq + p.weight_g + p.length_mm + lowlat::line::lane_for(p1::barcode_view(p));
}

void BM_DecodeMemcpy(benchmark::State& state) {
  const std::span<const std::byte> all{wire()};
  for (auto _ : state) {
    std::uint64_t sum = 0;
    for (std::size_t i = 0; i < kBatch; ++i) sum += work(*flat::decode_memcpy(record(all, i)));
    benchmark::DoNotOptimize(sum);
  }
  state.counters["ops_per_iteration"] = kBatch;
}

void BM_DecodeBitCast(benchmark::State& state) {
  const std::span<const std::byte> all{wire()};
  for (auto _ : state) {
    std::uint64_t sum = 0;
    for (std::size_t i = 0; i < kBatch; ++i) sum += work(*flat::decode_bit_cast(record(all, i)));
    benchmark::DoNotOptimize(sum);
  }
  state.counters["ops_per_iteration"] = kBatch;
}

void BM_DecodeStartLifetimeAs(benchmark::State& state) {
  const std::span<const std::byte> all{wire()};
  for (auto _ : state) {
    std::uint64_t sum = 0;
    for (std::size_t i = 0; i < kBatch; ++i) sum += work(**flat::view_start_lifetime_as(record(all, i)));
    benchmark::DoNotOptimize(sum);
  }
  state.counters["ops_per_iteration"] = kBatch;
}

const flat::TableData& table_data() {
  static const flat::TableData data = flat::make_table_data(kParcels, 2026);
  return data;
}

void BM_FlatTable(benchmark::State& state) {
  const flat::TableData& data = table_data();
  for (auto _ : state) {
    std::uint64_t weight = flat::sweep_due(data.by_slot, data.due_tick);
    benchmark::DoNotOptimize(weight);
  }
  state.counters["ops_per_iteration"] = 1;
}

void BM_PointerTable(benchmark::State& state) {
  static const auto table = flat::make_pointer_table(table_data());
  const std::uint64_t due = table_data().due_tick;
  for (auto _ : state) {
    std::uint64_t weight = flat::sweep_due(table, due);
    benchmark::DoNotOptimize(weight);
  }
  state.counters["ops_per_iteration"] = 1;
}

}  // namespace

BENCHMARK(BM_DecodeMemcpy)->Repetitions(30)->MinTime(0.1);
BENCHMARK(BM_DecodeBitCast)->Repetitions(30)->MinTime(0.1);
BENCHMARK(BM_DecodeStartLifetimeAs)->Repetitions(30)->MinTime(0.1);
BENCHMARK(BM_FlatTable)->Repetitions(10)->MinTime(0.3);
BENCHMARK(BM_PointerTable)->Repetitions(10)->MinTime(0.3);

BENCHMARK_MAIN();
