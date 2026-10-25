// RAII priority-inheritance mutex.
//
// std::mutex has no priority-inheritance option: the standard library offers no way to ask for
// PTHREAD_PRIO_INHERIT. pthread_mutexattr_setprotocol is therefore the one non-std lock in this example.
// PiMutex meets BasicLockable and Lockable, so std::lock_guard and std::unique_lock work with it.
#pragma once

#include <pthread.h>

#include <cerrno>
#include <exception>
#include <system_error>

namespace lowlat::pi {

enum class Protocol { none = PTHREAD_PRIO_NONE, inherit = PTHREAD_PRIO_INHERIT };

class PiMutex {
 public:
  explicit PiMutex(Protocol protocol = Protocol::inherit) : protocol_(protocol) {
    pthread_mutexattr_t attr;
    check(pthread_mutexattr_init(&attr), "pthread_mutexattr_init");
    // The attribute object is only needed to initialise the mutex; this guard frees it on every path, including a throw.
    const struct AttrGuard {
      pthread_mutexattr_t* attr;
      ~AttrGuard() { pthread_mutexattr_destroy(attr); }
    } guard{&attr};
    configure(attr, protocol);
    check(pthread_mutex_init(&mutex_, &attr), "pthread_mutex_init");
  }
  ~PiMutex() { pthread_mutex_destroy(&mutex_); }
  PiMutex(const PiMutex&) = delete;
  PiMutex& operator=(const PiMutex&) = delete;

  void lock() { check(pthread_mutex_lock(&mutex_), "pthread_mutex_lock"); }

  /// true when the lock was taken, false when it is held (EBUSY); any other error throws.
  [[nodiscard]] bool try_lock() {
    const int rc = pthread_mutex_trylock(&mutex_);
    if (rc == EBUSY) return false;
    check(rc, "pthread_mutex_trylock");
    return true;
  }

  /// unlock cannot throw out of std::lock_guard's destructor, and an error here (EPERM: not the owner) means the
  /// lock protocol is already broken, so it terminates rather than carry on.
  void unlock() noexcept {
    if (pthread_mutex_unlock(&mutex_) != 0) std::terminate();
  }

  [[nodiscard]] Protocol protocol() const noexcept { return protocol_; }

  /// Sets the protocol on an attribute object. Public so a test can read it back with pthread_mutexattr_getprotocol.
  static void configure(pthread_mutexattr_t& attr, Protocol protocol) {
    check(pthread_mutexattr_setprotocol(&attr, static_cast<int>(protocol)), "pthread_mutexattr_setprotocol");
  }

 private:
  static void check(int rc, const char* call) {
    if (rc != 0) throw std::system_error(rc, std::system_category(), call);
  }

  Protocol protocol_;
  pthread_mutex_t mutex_{};
};

}  // namespace lowlat::pi
