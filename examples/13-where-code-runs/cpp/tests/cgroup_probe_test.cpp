#include "cgroup_probe.hpp"

#include <gtest/gtest.h>

#include <cerrno>
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
    paths_.online_cpus = base_ / "online";
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

  void write(const std::string& relative_dir, const std::string& name, const std::string& text) {
    const fs::path dir = paths_.cgroup_root / relative_dir;
    fs::create_directories(dir);
    std::ofstream(dir / name) << text;
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

TEST(QuotaCpus, RoundsUpLikeAJvm) {
  EXPECT_EQ(quota_cpus(*parse_cpu_max("200000 100000")), 2);
  EXPECT_EQ(quota_cpus(*parse_cpu_max("150000 100000")), 2);
  EXPECT_EQ(quota_cpus(*parse_cpu_max("50000 100000")), 1);
  EXPECT_FALSE(quota_cpus(*parse_cpu_max("max 100000")).has_value());
}

TEST(CountCpus, CountsListsAndRanges) {
  EXPECT_EQ(count_cpus("2-3").value(), 2U);
  EXPECT_EQ(count_cpus("0-3,8\n").value(), 5U);
  EXPECT_EQ(count_cpus("7").value(), 1U);
  EXPECT_FALSE(count_cpus(""));
  EXPECT_FALSE(count_cpus("3-1"));
  EXPECT_FALSE(count_cpus("a-b"));
}

TEST(ParseCpuStat, ReadsKeysAndThrottlingCounters) {
  const auto stat = parse_cpu_stat("usage_usec 100\nnr_periods 7\nnr_throttled 3\nthrottled_usec 4200\n");
  ASSERT_TRUE(stat.has_value()) << stat.error();
  EXPECT_EQ(stat->get("nr_throttled"), 3U);
  EXPECT_EQ(stat->get("throttled_usec"), 4200U);
  EXPECT_FALSE(stat->get("nr_bursts").has_value());
}

TEST(ParseCpuStat, RejectsMalformedText) {
  EXPECT_FALSE(parse_cpu_stat(""));
  EXPECT_FALSE(parse_cpu_stat("usage_usec"));
  EXPECT_FALSE(parse_cpu_stat("usage_usec lots\n"));
}

TEST_F(FakeCgroup, CpusetEffectiveInTheOwnCgroup) {
  own("/job.slice");
  write("job.slice", "cpuset.cpus.effective", "2-3\n");
  const auto result = read_cpuset_effective(paths_);
  ASSERT_TRUE(result.has_value()) << result.error();
  EXPECT_EQ(*result, "2-3");
}

TEST_F(FakeCgroup, CpusetEffectiveWalksUpToTheNearestAncestor) {
  own("/a.slice/leaf.scope");
  fs::create_directories(paths_.cgroup_root / "a.slice/leaf.scope");
  write("", "cpuset.cpus.effective", "0-3\n");
  const auto result = read_cpuset_effective(paths_);
  ASSERT_TRUE(result.has_value()) << result.error();
  EXPECT_EQ(*result, "0-3");
}

TEST_F(FakeCgroup, MissingCpusetIsAnError) {
  own("/job.slice");
  fs::create_directories(paths_.cgroup_root / "job.slice");
  EXPECT_FALSE(read_cpuset_effective(paths_).has_value());
}

TEST_F(FakeCgroup, CpuStatOfTheOwnCgroupOnly) {
  own("/job.slice");
  write("job.slice", "cpu.stat", "usage_usec 9\nnr_throttled 12\nthrottled_usec 3400\n");
  write("", "cpu.stat", "usage_usec 1\nnr_throttled 99\n");
  const auto result = read_cpu_stat(paths_);
  ASSERT_TRUE(result.has_value()) << result.error();
  EXPECT_EQ(result->get("nr_throttled"), 12U);  // the cgroup's own counter, not the root's
}

TEST_F(FakeCgroup, CpuStatMissingIsAnError) {
  own("/job.slice");
  fs::create_directories(paths_.cgroup_root / "job.slice");
  const auto result = read_cpu_stat(paths_);
  ASSERT_FALSE(result.has_value());
  EXPECT_NE(result.error().find("cannot open"), std::string::npos);
}

TEST_F(FakeCgroup, OnlineCpusIsTheKernelsListNotTheCgroups) {
  std::ofstream(paths_.online_cpus) << "0-3\n";
  const auto result = read_online_cpus(paths_);
  ASSERT_TRUE(result.has_value()) << result.error();
  EXPECT_EQ(*result, "0-3");
  EXPECT_FALSE(read_online_cpus(Paths{.online_cpus = base_ / "absent"}).has_value());
}

TEST(IoUringSetup, ReportsZeroOrAnErrnoThePlanNames) {
  // 0 where io_uring works, EPERM under a seccomp filter or io_uring_disabled, ENOSYS where the kernel has none.
  const int err = io_uring_setup_errno();
  EXPECT_TRUE(err == 0 || err == EPERM || err == ENOSYS || err == ENOMEM || err == EACCES) << "errno " << err;
  EXPECT_FALSE(errno_name(err).empty());
}

TEST(ErrnoName, NamesTheErrnosTheProbeMeets) {
  EXPECT_EQ(errno_name(0), "ok");
  EXPECT_EQ(errno_name(EPERM), "EPERM");
  EXPECT_EQ(errno_name(ENOSYS), "ENOSYS");
}

}  // namespace lowlat::place
