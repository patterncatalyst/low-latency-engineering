#include "pi_mutex.hpp"

#include <gtest/gtest.h>

#include <mutex>
#include <thread>

namespace lowlat::pi {
namespace {

// Pure logic: nothing here needs SCHED_FIFO, root or a particular CPU.
TEST(PiMutex, DefaultsToPriorityInheritance) {
  PiMutex mutex;
  EXPECT_EQ(mutex.protocol(), Protocol::inherit);
}

TEST(PiMutex, ConfigureSetsThePriorityInheritanceAttribute) {
  pthread_mutexattr_t attr;
  ASSERT_EQ(pthread_mutexattr_init(&attr), 0);
  PiMutex::configure(attr, Protocol::inherit);
  int value = -1;
  ASSERT_EQ(pthread_mutexattr_getprotocol(&attr, &value), 0);
  EXPECT_EQ(value, PTHREAD_PRIO_INHERIT);
  PiMutex::configure(attr, Protocol::none);
  ASSERT_EQ(pthread_mutexattr_getprotocol(&attr, &value), 0);
  EXPECT_EQ(value, PTHREAD_PRIO_NONE);
  pthread_mutexattr_destroy(&attr);
}

TEST(PiMutex, PlainProtocolIsAvailableForTheContrastRun) {
  PiMutex mutex{Protocol::none};
  EXPECT_EQ(mutex.protocol(), Protocol::none);
}

TEST(PiMutex, WorksWithTheStandardGuards) {
  PiMutex mutex;
  int counter = 0;
  {
    std::jthread a{[&] { for (int i = 0; i < 1000; ++i) { std::lock_guard guard{mutex}; ++counter; } }};
    std::jthread b{[&] { for (int i = 0; i < 1000; ++i) { std::scoped_lock guard{mutex}; ++counter; } }};
  }
  EXPECT_EQ(counter, 2000);
  EXPECT_TRUE(mutex.try_lock());
  // A held lock is "busy" (false), not an error: checked from another thread, since a PI mutex is not recursive.
  bool second = true;
  std::jthread{[&] { second = mutex.try_lock(); }}.join();
  EXPECT_FALSE(second);
  mutex.unlock();
}

}  // namespace
}  // namespace lowlat::pi
