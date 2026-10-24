// Coroutine frames, counted. A minimal lazy Task<T> whose promise counts every frame allocation, with
// symmetric transfer both when a task finishes and when two coroutines hand a turn to each other.
//
// Why a hand-rolled Task: the standard library has no task type before C++26 std::execution, which GCC 16
// does not ship, and Asio's awaitable keeps its frames in its own recycling allocator where a counter
// cannot see them. The Task is used for the ping-pong and the frame probes only; the waits themselves
// (the line and the neighbour workload) run on Asio's awaitable and steady_timer.
// Provenance: adapted from the Task<T> and the promise-level operator new probe in the companion
// project cpp-concurrency-and-parallelism, example 11-coroutines-in-depth, brought up to C++23.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <coroutine>
#include <exception>
#include <new>
#include <optional>
#include <type_traits>
#include <utility>

namespace lowlat::tasks {

/// Coroutine frame allocations made through a Task promise. Exact for the frames it sees; a frame the
/// compiler elides (HALO) never reaches it. Padded so a counter on another thread never shares its line.
struct alignas(std::hardware_destructive_interference_size) FrameCounter {
  std::atomic<std::uint64_t> allocations{0};
  std::atomic<std::uint64_t> frees{0};
  std::atomic<std::uint64_t> bytes{0};
  std::atomic<std::uint64_t> last_bytes{0};
};

inline FrameCounter g_frames;

struct FrameSnapshot {
  std::uint64_t allocations = 0;
  std::uint64_t frees = 0;
  std::uint64_t bytes = 0;
};

[[nodiscard]] inline FrameSnapshot frame_snapshot() noexcept {
  return {g_frames.allocations.load(std::memory_order_relaxed), g_frames.frees.load(std::memory_order_relaxed),
          g_frames.bytes.load(std::memory_order_relaxed)};
}

template <class T>
class Task;

namespace detail {

struct PromiseBase {
  std::coroutine_handle<> continuation = std::noop_coroutine();
  std::exception_ptr error;

  static void* operator new(std::size_t n) {
    g_frames.allocations.fetch_add(1, std::memory_order_relaxed);
    g_frames.bytes.fetch_add(n, std::memory_order_relaxed);
    g_frames.last_bytes.store(n, std::memory_order_relaxed);
    return ::operator new(n);
  }
  static void operator delete(void* p, std::size_t) noexcept {
    g_frames.frees.fetch_add(1, std::memory_order_relaxed);
    ::operator delete(p);
  }

  std::suspend_always initial_suspend() const noexcept { return {}; }

  // Symmetric transfer: the finished task hands control to whoever awaited it as a tail call, so a chain
  // of awaited tasks costs no stack however long it is.
  struct Final {
    bool await_ready() const noexcept { return false; }
    template <class P>
    std::coroutine_handle<> await_suspend(std::coroutine_handle<P> h) const noexcept {
      return h.promise().continuation;
    }
    void await_resume() const noexcept {}
  };
  Final final_suspend() const noexcept { return {}; }

  void unhandled_exception() noexcept { error = std::current_exception(); }
};

template <class T>
struct Promise : PromiseBase {
  std::optional<T> value;
  Task<T> get_return_object() noexcept;
  void return_value(T v) { value = std::move(v); }
};

template <>
struct Promise<void> : PromiseBase {
  Task<void> get_return_object() noexcept;
  void return_void() const noexcept {}
};

}  // namespace detail

template <class T = void>
class [[nodiscard]] Task {
 public:
  using promise_type = detail::Promise<T>;
  using Handle = std::coroutine_handle<promise_type>;

  explicit Task(Handle h) noexcept : handle_{h} {}
  Task(Task&& other) noexcept : handle_{std::exchange(other.handle_, {})} {}
  Task& operator=(Task&& other) noexcept {
    if (this != &other) {
      destroy();
      handle_ = std::exchange(other.handle_, {});
    }
    return *this;
  }
  Task(const Task&) = delete;
  Task& operator=(const Task&) = delete;
  ~Task() { destroy(); }

  // co_await task: record the awaiter as the continuation and transfer into the task.
  [[nodiscard]] bool await_ready() const noexcept { return false; }
  std::coroutine_handle<> await_suspend(std::coroutine_handle<> awaiting) noexcept {
    handle_.promise().continuation = awaiting;
    return handle_;
  }
  T await_resume() { return take(); }

  /// Runs a root task from ordinary code until it first suspends for good or finishes.
  void start() { handle_.resume(); }
  [[nodiscard]] bool done() const noexcept { return handle_.done(); }
  [[nodiscard]] std::coroutine_handle<> handle() const noexcept { return handle_; }

  /// The result of a finished root task (rethrows what the coroutine threw).
  T result() { return take(); }

 private:
  T take() {
    if (handle_.promise().error) std::rethrow_exception(handle_.promise().error);
    if constexpr (!std::is_void_v<T>) return std::move(*handle_.promise().value);
  }
  void destroy() noexcept {
    if (handle_) handle_.destroy();
    handle_ = {};
  }
  Handle handle_;
};

namespace detail {
template <class T>
Task<T> Promise<T>::get_return_object() noexcept {
  return Task<T>{std::coroutine_handle<Promise<T>>::from_promise(*this)};
}
inline Task<void> Promise<void>::get_return_object() noexcept {
  return Task<void>{std::coroutine_handle<Promise<void>>::from_promise(*this)};
}
}  // namespace detail

/// A value on its own cache line, for a slot two coroutines or threads hand back and forth.
struct alignas(std::hardware_destructive_interference_size) PaddedSlot {
  std::uint64_t v = 0;
};

/// Suspends the awaiting coroutine, parking its handle in `self`, and resumes `peer` by symmetric
/// transfer: no scheduler, no queue, one indirect jump. Two coroutines that each co_await a Transfer
/// aimed at the other play ping-pong on one OS thread.
struct Transfer {
  std::coroutine_handle<>& self;
  std::coroutine_handle<>& peer;
  [[nodiscard]] bool await_ready() const noexcept { return false; }
  std::coroutine_handle<> await_suspend(std::coroutine_handle<> me) const noexcept {
    self = me;
    return peer;
  }
  void await_resume() const noexcept {}
};

}  // namespace lowlat::tasks
