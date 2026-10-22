// SIGINT / SIGTERM -> one shared stop flag, for the programs that run until told to stop.
#pragma once

#include <csignal>

#include <atomic>
#include <cerrno>
#include <system_error>

namespace lowlat::line {

/// Set by the signal handler, polled by the program's loop. A lock-free atomic
/// store is async-signal-safe.
inline std::atomic<bool> g_stop{false};
static_assert(std::atomic<bool>::is_always_lock_free);

extern "C" inline void on_stop_signal(int) { g_stop.store(true, std::memory_order_relaxed); }

/// Installs the handler for SIGINT and SIGTERM without SA_RESTART, so a blocking
/// recv or clock_nanosleep returns early (EINTR) and the loop sees `g_stop`.
/// Throws std::system_error if sigaction fails.
inline void install_stop_handlers() {
  struct sigaction sa {};
  sa.sa_handler = on_stop_signal;
  sigemptyset(&sa.sa_mask);
  for (const int sig : {SIGINT, SIGTERM}) {
    if (::sigaction(sig, &sa, nullptr) != 0) throw std::system_error(errno, std::generic_category(), "sigaction");
  }
}

}  // namespace lowlat::line
