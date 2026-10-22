// The three decode variants agree with each other and with the golden bytes; the view refuses a
// misaligned buffer that the copying variants accept; the two table layouts give the same sweep.
#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <ranges>
#include <span>
#include <string>
#include <vector>

#include "lowlat/flat/decode.hpp"
#include "lowlat/flat/table.hpp"

namespace {

namespace flat = lowlat::flat;
namespace p1 = lowlat::flat::parcel_v1;

std::vector<std::byte> read_golden(long seed) {
  const auto path = std::filesystem::path{LOWLAT_FLAT_GOLDEN_DIR} / ("golden-seed" + std::to_string(seed) + ".bin");
  std::ifstream in{path, std::ios::binary};
  EXPECT_TRUE(in) << path;
  const std::vector<char> raw{std::istreambuf_iterator<char>{in}, std::istreambuf_iterator<char>{}};
  const auto bytes = std::as_bytes(std::span{raw});
  return {bytes.begin(), bytes.end()};
}

bool same_bytes(const p1::Parcel& a, const p1::Parcel& b) { return std::memcmp(&a, &b, sizeof a) == 0; }

class GoldenSeeds : public testing::TestWithParam<long> {};

TEST_P(GoldenSeeds, ThreeVariantsReadTheSameRecords) {
  const std::vector<std::byte> bytes = read_golden(GetParam());
  ASSERT_GT(bytes.size(), 0U);
  ASSERT_EQ(bytes.size() % p1::kSize, 0U);
  // std::vector storage is aligned for any fundamental type, and 80 is a multiple of 8.
  for (std::size_t at = 0; at < bytes.size(); at += p1::kSize) {
    const std::span<const std::byte> record = std::span{bytes}.subspan(at, p1::kSize);
    const auto copied = flat::decode_memcpy(record);
    const auto cast = flat::decode_bit_cast(record);
    const auto viewed = flat::view_start_lifetime_as(record);
    ASSERT_TRUE(copied && cast && viewed) << "record at " << at;
    EXPECT_TRUE(same_bytes(*copied, *cast)) << at;
    EXPECT_TRUE(same_bytes(*copied, **viewed)) << at;
    const p1::Bytes again = p1::encode(*copied);
    EXPECT_TRUE(std::ranges::equal(again, record)) << "re-encoding gives the golden bytes back, record at " << at;
  }
}

INSTANTIATE_TEST_SUITE_P(Contract, GoldenSeeds, testing::Values(1L, 42L, 2026L));

TEST(FlatDecode, HeaderIsCheckedBeforeSizeInEveryVariant) {
  p1::Bytes good = p1::encode(p1::Parcel{});
  std::array<std::byte, 2 * p1::kSize> twice{};
  std::ranges::copy(good, twice.begin());

  const auto expect_error = [](std::span<const std::byte> bytes, p1::DecodeError want) {
    EXPECT_EQ(flat::decode_memcpy(bytes).error(), want);
    EXPECT_EQ(flat::decode_bit_cast(bytes).error(), want);
    const auto view = flat::view_start_lifetime_as(bytes);
    ASSERT_FALSE(view);
    EXPECT_EQ(static_cast<int>(view.error()), static_cast<int>(want));  // same names, same order
  };
  expect_error(std::span{good}.first(3), p1::DecodeError::wrong_size);
  expect_error(std::span{good}.first(p1::kSize - 1), p1::DecodeError::wrong_size);
  expect_error(std::span{twice}, p1::DecodeError::wrong_size);  // version 1 is exactly 80 bytes

  std::array<std::byte, 2 * p1::kSize> v2 = twice;
  v2[2] = std::byte{2};  // version 2 (little-endian u16 at offset 2), and the buffer is larger
  expect_error(std::span{v2}, p1::DecodeError::unsupported_version);  // not "wrong size"
  std::array<std::byte, p1::kSize> other = good;
  other[0] = std::byte{9};
  expect_error(std::span{other}, p1::DecodeError::wrong_schema);
}

TEST(FlatDecode, ViewRefusesAMisalignedBufferTheCopyingVariantsAccept) {
  alignas(8) std::array<std::byte, p1::kSize + 8> storage{};
  const p1::Bytes good = p1::encode(p1::Parcel{.seq = 42});
  std::ranges::copy(good, storage.begin() + 1);  // one byte off the 8-byte boundary
  const std::span<const std::byte> unaligned = std::span{storage}.subspan(1, p1::kSize);

  const auto view = flat::view_start_lifetime_as(unaligned);
  ASSERT_FALSE(view);
  EXPECT_EQ(view.error(), flat::ViewError::misaligned);
  ASSERT_TRUE(flat::decode_memcpy(unaligned));
  EXPECT_EQ(flat::decode_memcpy(unaligned)->seq, 42U);
  EXPECT_EQ(flat::decode_bit_cast(unaligned)->seq, 42U);

  std::ranges::copy(good, storage.begin());
  const auto aligned = flat::view_start_lifetime_as(std::span{storage}.first(p1::kSize));
  ASSERT_TRUE(aligned);
  EXPECT_EQ((*aligned)->seq, 42U);
}

TEST(FlatTable, BothLayoutsSweepTheSame) {
  const flat::TableData data = flat::make_table_data(20'000, 7);
  const auto pointers = flat::make_pointer_table(data);
  ASSERT_EQ(pointers.size(), data.by_slot.size());
  EXPECT_EQ(flat::sweep_due(data.by_slot, data.due_tick), flat::sweep_due(pointers, data.due_tick));
  EXPECT_GT(flat::sweep_due(data.by_slot, data.due_tick), 0U);
  EXPECT_EQ(flat::sweep_due(data.by_slot, 0), flat::sweep_due(pointers, 0));
  EXPECT_EQ(flat::sweep_due(data.by_slot, ~std::uint64_t{0}), flat::sweep_due(pointers, ~std::uint64_t{0}));
  // Slots are a shuffle of arrival order, not arrival order itself.
  const auto in_order = std::ranges::count_if(std::views::iota(std::size_t{1}, data.by_slot.size()), [&](std::size_t i) {
    return data.by_slot[i].seq == data.by_slot[i - 1].seq + 1;
  });
  EXPECT_LT(in_order, 100);
}

}  // namespace
