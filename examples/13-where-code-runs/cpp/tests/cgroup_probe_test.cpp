#include "cgroup_probe.hpp"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

namespace lowlat::place {
namespace fs = std::filesystem;

// A fake /sys/fs/cgroup and /proc/self/cgroup in a temporary directory.
class FakeCgroup : public testing::Test {
 protected:
  void SetUp() override {
    base_ = fs::temp_directory_path() / ("cgroup_probe_" + std::to_string(::testing::UnitTest::GetInstance()->random_seed()) +
                                         "_" + testing::UnitTest::GetInstance()->current_test_info()->name());
    fs::remove_all(base_);
    fs::create_directories(base_ / "root");
    paths_.cgroup_root = base_ / "root";
    paths_.proc_self_cgroup = base_ / "proc_self_cgroup";
  }
  void TearDown() override { fs::remove_all(base_); }

  void own(const std::string& cgroup_path) {
    std::ofstream(paths_.proc_self_cgroup) << "0::" << cgroup_path << "\n";
  }
  void cpu_max(const std::string& relative_dir, const std::string& text) {
    const fs::path dir = paths_.cgroup_root / relative_dir;
    fs::create_directories(dir);
    std::ofstream(dir / "cpu.max") << text << "\n";
  }

  fs::path base_;
  Paths paths_;
};

TEST(ParseCpuMax, ReadsQuotaAndPeriod) {
  const auto limited = parse_cpu_max("200000 100000\n");
  ASSERT_TRUE(limited.has_value());
  EXPECT_EQ(limited->quota_us, 200000);
  EXPECT_EQ(limited->period_us, 100000);
  const auto unlimited = parse_cpu_max("max 100000\n");
  ASSERT_TRUE(unlimited.has_value());
  EXPECT_FALSE(unlimited->quota_us.has_value());
}

TEST(ParseCpuMax, RejectsMalformedText) {
  EXPECT_FALSE(parse_cpu_max("garbage"));
  EXPECT_FALSE(parse_cpu_max("abc 100000"));
}

TEST_F(FakeCgroup, QuotaInTheOwnCgroup) {
  own("/job.slice");
  cpu_max("job.slice", "200000 100000");
  const auto result = read_cpu_max(paths_);
  ASSERT_TRUE(result.has_value()) << result.error();
  EXPECT_EQ(result->quota_us, 200000);
  EXPECT_EQ(result->period_us, 100000);
}

TEST_F(FakeCgroup, NoQuotaIsMax) {
  own("/job.slice");
  cpu_max("job.slice", "max 100000");
  const auto result = read_cpu_max(paths_);
  ASSERT_TRUE(result.has_value()) << result.error();
  EXPECT_FALSE(result->quota_us.has_value());
}

TEST_F(FakeCgroup, WalksUpToTheNearestAncestorWithCpuMax) {
  own("/a.slice/b.slice/leaf.scope");
  fs::create_directories(paths_.cgroup_root / "a.slice/b.slice/leaf.scope");
  cpu_max("a.slice", "50000 100000");
  const auto result = read_cpu_max(paths_);
  ASSERT_TRUE(result.has_value()) << result.error();
  EXPECT_EQ(result->quota_us, 50000);
}

TEST_F(FakeCgroup, ContainerNamespaceRootIsTheCgroupRoot) {
  own("/");
  cpu_max("", "300000 100000");
  const auto result = read_cpu_max(paths_);
  ASSERT_TRUE(result.has_value()) << result.error();
  EXPECT_EQ(result->quota_us, 300000);
}

TEST_F(FakeCgroup, MissingCpuMaxEverywhereIsAnError) {
  own("/a.slice/leaf.scope");
  fs::create_directories(paths_.cgroup_root / "a.slice/leaf.scope");
  const auto result = read_cpu_max(paths_);
  ASSERT_FALSE(result.has_value());
  EXPECT_NE(result.error().find("no cpu.max"), std::string::npos);
}

TEST_F(FakeCgroup, MissingProcFileIsAnError) {
  const auto result = read_cpu_max(paths_);
  ASSERT_FALSE(result.has_value());
  EXPECT_NE(result.error().find("cannot open"), std::string::npos);
}

TEST_F(FakeCgroup, CgroupV1OnlyProcFileIsAnError) {
  std::ofstream(paths_.proc_self_cgroup) << "4:cpu:/legacy\n";
  EXPECT_FALSE(read_cpu_max(paths_).has_value());
}

}  // namespace lowlat::place
