// RAII priority-inheritance mutex.
//
// std::mutex has no priority-inheritance option: the standard library offers no way to ask for
// PTHREAD_PRIO_INHERIT. pthread_mutexattr_setprotocol is therefore the one non-std lock in this example.
// PiMutex meets BasicLockable and Lockable, so std::lock_guard and std::unique_lock work with it.
#pragma once

#include <pthread.h>

#include <system_error>

namespace lowlat::pi {

enum class Protocol { none = PTHREAD_PRIO_NONE, inherit = PTHREAD_PRIO_INHERIT };

class PiMutex {
 public:
  explicit PiMutex(Protocol protocol = Protocol::inherit) {
    check(pthread_mutexattr_init(&attr_), "pthread_mutexattr_init");
    check(pthread_mutexattr_setprotocol(&attr_, static_cast<int>(protocol)), "pthread_mutexattr_setprotocol");
    check(pthread_mutex_init(&mutex_, &attr_), "pthread_mutex_init");
  }
  ~PiMutex() {
    pthread_mutex_destroy(&mutex_);
    pthread_mutexattr_destroy(&attr_);
  }
  PiMutex(const PiMutex&) = delete;
  PiMutex& operator=(const PiMutex&) = delete;

  void lock() { check(pthread_mutex_lock(&mutex_), "pthread_mutex_lock"); }
  [[nodiscard]] bool try_lock() noexcept { return pthread_mutex_trylock(&mutex_) == 0; }
  void unlock() noexcept { pthread_mutex_unlock(&mutex_); }

  /// The protocol stored in the attribute object, read back from the C library (not from a field of ours).
  [[nodiscard]] Protocol protocol() const {
    int value = 0;
    check(pthread_mutexattr_getprotocol(&attr_, &value), "pthread_mutexattr_getprotocol");
    return static_cast<Protocol>(value);
  }

 private:
  static void check(int rc, const char* call) {
    if (rc != 0) throw std::system_error(rc, std::system_category(), call);
  }

  pthread_mutexattr_t attr_{};
  pthread_mutex_t mutex_{};
};

}  // namespace lowlat::pi
