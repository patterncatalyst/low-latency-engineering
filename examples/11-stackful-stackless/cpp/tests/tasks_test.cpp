#include "tasks.hpp"

#include <gtest/gtest.h>

#include <vector>

namespace lowlat::tasks {

TEST(Tasks, GeneratorYieldsParcelIdsInOrder) {
  std::vector<int> ids;
  for (int id : parcel_ids(3)) {
    ids.push_back(id);
  }
  EXPECT_EQ(ids, (std::vector<int>{1, 2, 3}));
}

TEST(Tasks, OneFiberRuns) { EXPECT_EQ(run_one_fiber(7), 7); }

TEST(Tasks, OneAwaitableRunsThroughCoSpawn) { EXPECT_EQ(run_one_awaitable(9), 9); }

}  // namespace lowlat::tasks
