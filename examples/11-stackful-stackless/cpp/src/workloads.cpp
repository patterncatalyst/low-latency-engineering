// Provenance: the fiber setup (Boost.Fiber on protected_fixedsize_stack, a buffered_channel hand-off) is
// adapted from the companion project cpp-concurrency-and-parallelism, example 13-fiber-worker-pool, and the
// coroutine frame probe from its example 11-coroutines-in-depth, both brought up to C++23.
#include "lowlat/tasks/workloads.hpp"

#include <boost/asio/awaitable.hpp>
#include <boost/asio/co_spawn.hpp>
#include <boost/asio/detached.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/steady_timer.hpp>
#include <boost/asio/this_coro.hpp>
#include <boost/asio/use_awaitable.hpp>
#include <boost/context/protected_fixedsize_stack.hpp>
#include <boost/fiber/all.hpp>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <coroutine>
#include <format>
#include <latch>
#include <memory>
#include <mutex>
#include <semaphore>
#include <stop_token>
#include <thread>

#include "lowlat/line/clock.hpp"
#include "lowlat/tasks/frames.hpp"
#include "lowlat/tasks/parcels.hpp"
#include "lowlat/tasks/procinfo.hpp"
#include "lowlat/tasks/sink.hpp"

namespace lowlat::tasks {

namespace asio = boost::asio;

namespace {

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

std::int64_t now_ns() noexcept { return line::monotonic_ns(); }
Clock::time_point at(std::int64_t ns) { return Clock::time_point{std::chrono::nanoseconds{ns}}; }
std::int64_t positive(std::int64_t v) noexcept { return v < 1 ? 1 : v; }
std::int64_t ns_of(auto d) { return std::chrono::duration_cast<std::chrono::nanoseconds>(d).count(); }

constexpr std::size_t kLine = std::hardware_destructive_interference_size;

CtxSwitches since(const CtxSwitches& start) {
  const CtxSwitches now = thread_ctx_switches();
  return {now.voluntary - start.voluntary, now.involuntary - start.involuntary};
}

/// Runs `body` on one worker thread behind the gate (pinned to `cpu`) while the calling thread releases it.
template <class F>
std::expected<void, std::string> on_worker(Gate& gate, int cpu, std::string role, F&& body) {
  std::string error;
  std::thread worker{[&] {
    try {
      gate.worker_ready(cpu, std::move(role));
      body();
    } catch (const std::exception& e) {
      error = e.what();
    }
  }};
  gate.release();
  worker.join();
  if (auto pin = gate.error()) return std::unexpected(*pin);
  if (!error.empty()) return std::unexpected(error);
  return {};
}

void add_memory(Run& r, const MemorySnapshot& before, const MemorySnapshot& parked, std::size_t tasks) {
  const auto grew = [](std::int64_t a, std::int64_t b) { return std::max<std::int64_t>(0, b - a); };
  const std::int64_t rss = grew(before.rss_kib, parked.rss_kib);
  const std::int64_t vsize = grew(before.vm_size_kib, parked.vm_size_kib);
  const std::int64_t pte = grew(before.page_tables_kib, parked.page_tables_kib);
  const std::int64_t kstack = grew(before.kernel_stack_kib, parked.kernel_stack_kib);
  const auto n = static_cast<std::int64_t>(tasks);
  r.counters["rss_before_kib"] = before.rss_kib;
  r.counters["rss_parked_kib"] = parked.rss_kib;
  r.counters["rss_delta_kib"] = rss;
  r.counters["vm_size_delta_kib"] = vsize;
  r.counters["vm_size_bytes_per_task"] = vsize * 1024 / n;
  r.counters["page_tables_delta_kib"] = pte;
  r.counters["kernel_stack_delta_kib"] = kstack;
  r.counters["rss_bytes_per_task"] = rss * 1024 / n;
  r.counters["rss_page_tables_kernel_stack_bytes_per_task"] = (rss + pte + kstack) * 1024 / n;
}

void add_lateness(Run& r, const std::vector<std::int64_t>& woke, std::int64_t deadline) {
  r.samples.reserve(woke.size());
  for (const std::int64_t w : woke) r.samples.push_back(positive(w - deadline));
}

// ---- timer awaiter for the Task probes ------------------------------------------------------------------------------

struct TimerWait {
  asio::steady_timer& timer;
  [[nodiscard]] bool await_ready() const noexcept { return false; }
  void await_suspend(std::coroutine_handle<> h) { timer.async_wait([h](const boost::system::error_code&) { h.resume(); }); }
  void await_resume() const noexcept {}
};

// The shape of one lookup wait: the parcel's fields in the frame, a timer in the frame, one suspension.
Task<> lookup_frame(asio::io_context& ctx, std::uint64_t seq, std::int64_t intended_ns, Clock::time_point when) {
  asio::steady_timer timer{ctx, when};
  co_await TimerWait{timer};
  sink(seq + static_cast<std::uint64_t>(intended_ns));
}

Task<int> control_frame(int x) { co_return x + 1; }

}  // namespace

std::optional<Variant> parse_variant(std::string_view name) {
  if (name == "os-thread") return Variant::os_thread;
  if (name == "fiber") return Variant::fiber;
  if (name == "coroutine") return Variant::coroutine;
  return std::nullopt;
}

std::string_view name_of(Variant v) {
  switch (v) {
    case Variant::os_thread: return "os-thread";
    case Variant::fiber: return "fiber";
    case Variant::coroutine: return "coroutine";
  }
  return "?";
}

FrameProbe probe_frames(std::uint64_t n, std::uint64_t control) {
  FrameProbe out;
  {
    asio::io_context ctx{1};
    const FrameSnapshot before = frame_snapshot();
    std::vector<Task<>> frames;  // every frame is reachable from here until the timers have fired
    frames.reserve(n);
    const auto when = Clock::now() + 50ms;
    for (auto&& ev : parcels(n)) frames.push_back(lookup_frame(ctx, ev.seq(), ev.intended_emit_ns(), when));
    for (auto& f : frames) f.start();  // each runs to its co_await and parks
    const FrameSnapshot parked = frame_snapshot();
    out.parked_frames = n;
    out.allocations = parked.allocations - before.allocations;
    out.bytes = parked.bytes - before.bytes;
    ctx.run();
  }
  const FrameSnapshot c0 = frame_snapshot();
  std::uint64_t acc = 0;
  for (std::uint64_t i = 0; i < control; ++i) {
    Task<int> t = control_frame(static_cast<int>(i));  // created, run and destroyed here: free to be elided
    t.start();
    acc += static_cast<std::uint64_t>(t.result());
  }
  sink(acc);
  out.control_frames = control;
  out.control_allocations = frame_snapshot().allocations - c0.allocations;
  return out;
}

// ---- (a) parked -------------------------------------------------------------------------------------------------------

namespace {

std::expected<Run, std::string> parked_threads(const ParkedParams& p, Gate& gate) {
  const std::size_t n = p.tasks;
  std::latch armed{static_cast<std::ptrdiff_t>(n)};
  std::latch go{1};
  std::latch woken{static_cast<std::ptrdiff_t>(n)};
  std::atomic<std::int64_t> deadline{0};
  std::vector<std::int64_t> woke(n, 0);
  gate.release();  // no pinned workers here: the tasks float; this prints the markers verify.sh waits for
  const MemorySnapshot before = memory_snapshot();
  std::vector<std::jthread> threads;
  threads.reserve(n);
  try {
    for (std::size_t i = 0; i < n; ++i) {
      threads.emplace_back([&, i](const std::stop_token& stop) {
        armed.count_down();
        go.wait();
        const auto when = at(deadline.load(std::memory_order_acquire));
        std::mutex m;
        std::condition_variable_any cv;
        std::unique_lock lock{m};
        cv.wait_until(lock, stop, when, [] { return false; });  // parked until the deadline or a stop request
        woke[i] = now_ns();
        woken.count_down();
      });
    }
  } catch (const std::system_error& e) {
    deadline.store(now_ns(), std::memory_order_release);
    go.count_down();
    const std::size_t started = threads.size();
    threads.clear();
    return std::unexpected(std::format("could not start thread {} of {}: {}", started + 1, n, e.what()));
  }
  armed.wait();  // the handshake: every task is running and about to wait
  const std::int64_t when = now_ns() + ns_of(p.wait);
  deadline.store(when, std::memory_order_release);
  go.count_down();
  std::this_thread::sleep_for(p.wait / 2);
  const MemorySnapshot parked = memory_snapshot();
  woken.wait();     // a jthread's destructor requests a stop, which would end a wait early: let every wait run out first
  threads.clear();  // joins every jthread
  Run r;
  add_lateness(r, woke, when);
  r.counters["tasks"] = static_cast<std::int64_t>(n);
  r.counters["tasks_armed"] = static_cast<std::int64_t>(n);
  add_memory(r, before, parked, n);
  r.notes = std::format("parked; model=os-thread; stack=default ({} KiB virtual); wait_ms={}", 8192, p.wait.count());
  return r;
}

std::expected<Run, std::string> parked_fibers(const ParkedParams& p, Gate& gate) {
  const std::size_t n = p.tasks;
  Run r;
  std::vector<std::int64_t> woke(n, 0);
  std::int64_t when = 0;
  std::size_t armed = 0;
  MemorySnapshot before, parked;
  auto ran = on_worker(gate, p.cpu, "fibers", [&] {
    before = memory_snapshot();
    when = now_ns() + ns_of(p.wait);
    boost::context::protected_fixedsize_stack stack{kFiberStackBytes};
    std::vector<boost::fibers::fiber> fibers;
    fibers.reserve(n);
    for (std::size_t i = 0; i < n; ++i) {
      fibers.emplace_back(std::allocator_arg, stack, [&, i] {
        ++armed;
        boost::this_fiber::sleep_until(at(when));
        woke[i] = now_ns();
      });
    }
    boost::this_fiber::sleep_for(p.wait / 2);  // the fibers start now and park
    parked = memory_snapshot();
    for (auto& f : fibers) f.join();
  });
  if (!ran) return std::unexpected(ran.error());
  add_lateness(r, woke, when);
  r.cpus = gate.cpus();
  r.counters["tasks"] = static_cast<std::int64_t>(n);
  r.counters["tasks_armed"] = static_cast<std::int64_t>(armed);
  r.counters["fiber_stack_bytes"] = static_cast<std::int64_t>(kFiberStackBytes);
  add_memory(r, before, parked, n);
  r.notes = std::format("parked; model=fiber; stack=protected_fixedsize_stack({} KiB); wait_ms={}", kFiberStackBytes / 1024, p.wait.count());
  return r;
}

asio::awaitable<void> parked_waiter(std::int64_t when, std::int64_t* woke, std::size_t* armed) {
  asio::steady_timer timer{co_await asio::this_coro::executor, at(when)};
  ++*armed;
  co_await timer.async_wait(asio::use_awaitable);
  *woke = now_ns();
}

asio::awaitable<void> memory_after(std::chrono::milliseconds delay, MemorySnapshot* out) {
  asio::steady_timer timer{co_await asio::this_coro::executor, delay};
  co_await timer.async_wait(asio::use_awaitable);
  *out = memory_snapshot();
}

std::expected<Run, std::string> parked_coroutines(const ParkedParams& p, Gate& gate) {
  const std::size_t n = p.tasks;
  Run r;
  std::vector<std::int64_t> woke(n, 0);
  std::int64_t when = 0;
  std::size_t armed = 0;
  MemorySnapshot before, parked;
  FrameProbe probe;
  auto ran = on_worker(gate, p.cpu, "coroutines", [&] {
    asio::io_context ctx{1};
    before = memory_snapshot();
    when = now_ns() + ns_of(p.wait);
    for (std::size_t i = 0; i < n; ++i) asio::co_spawn(ctx, parked_waiter(when, &woke[i], &armed), asio::detached);
    asio::co_spawn(ctx, memory_after(p.wait / 2, &parked), asio::detached);
    ctx.run();
    probe = probe_frames(n, 1000);
  });
  if (!ran) return std::unexpected(ran.error());
  add_lateness(r, woke, when);
  r.cpus = gate.cpus();
  r.counters["tasks"] = static_cast<std::int64_t>(n);
  r.counters["tasks_armed"] = static_cast<std::int64_t>(armed);
  add_memory(r, before, parked, n);
  r.counters["frames_parked"] = static_cast<std::int64_t>(probe.parked_frames);
  r.counters["frame_allocations"] = static_cast<std::int64_t>(probe.allocations);
  r.counters["frame_bytes_total"] = static_cast<std::int64_t>(probe.bytes);
  r.counters["frame_bytes_per_task"] = probe.parked_frames == 0 ? 0 : static_cast<std::int64_t>(probe.bytes / probe.parked_frames);
  r.counters["control_frames"] = static_cast<std::int64_t>(probe.control_frames);
  r.counters["control_frame_allocations"] = static_cast<std::int64_t>(probe.control_allocations);
  r.notes = std::format(
      "parked; model=coroutine (asio awaitable + steady_timer); wait_ms={}; frame bytes are counted on Task coroutines "
      "that park on a steady_timer held in the frame, stored in a vector so no frame can be elided",
      p.wait.count());
  return r;
}

}  // namespace

std::expected<Run, std::string> run_parked(Variant v, const ParkedParams& p) {
  if (p.tasks == 0) return std::unexpected("--tasks must be at least 1");
  Gate gate{v == Variant::os_thread ? 0 : 1, p.hold};
  try {
    switch (v) {
      case Variant::os_thread: return parked_threads(p, gate);
      case Variant::fiber: return parked_fibers(p, gate);
      case Variant::coroutine: return parked_coroutines(p, gate);
    }
  } catch (const std::exception& e) {
    return std::unexpected(e.what());
  }
  return std::unexpected("unknown variant");
}

// ---- (b) ping-pong ------------------------------------------------------------------------------------------------------

namespace {

/// A one-token hand-off whose waiter sleeps in the kernel: pthread_cond_wait goes straight to a futex, with no
/// spinning first, so every hand-off is a sleep and a wake.
struct alignas(kLine) CondvarToken {
  std::mutex m;
  std::condition_variable cv;
  bool ready = false;
  void post() {
    {
      const std::scoped_lock lock{m};
      ready = true;
    }
    cv.notify_one();
  }
  void wait() {
    std::unique_lock lock{m};
    cv.wait(lock, [this] { return ready; });
    ready = false;
  }
};

/// The same hand-off on std::binary_semaphore. libstdc++ spins briefly before it sleeps, so a hot ping-pong
/// between two cores can complete without either thread entering the kernel (the run records how often it did).
struct alignas(kLine) SemaphoreToken {
  std::binary_semaphore s{0};
  void post() { s.release(); }
  void wait() { s.acquire(); }
};

template <class Token>
struct Shared {
  Token ping, pong;
  PaddedSlot slot;
};

/// What A adds up over every turn: the slot after B added 1 to the value A stored, 0..batch-1.
std::uint64_t expected_acc(const PingPongParams& p) {
  return (p.warmup_batches + p.rounds / p.batch) * (p.batch * (p.batch + 1) / 2);
}

void finish_pingpong(Run& r, const PingPongParams& p, std::uint64_t acc, std::uint64_t served, const CtxSwitches& a,
                     const CtxSwitches& b, const Gate& gate) {
  sink(acc);
  r.ctx = {a.voluntary + b.voluntary, a.involuntary + b.involuntary};
  r.cpus = gate.cpus();
  r.counters["round_trips"] = static_cast<std::int64_t>(p.rounds);
  r.counters["round_trips_served"] = static_cast<std::int64_t>(served);
  r.counters["warmup_round_trips"] = static_cast<std::int64_t>(p.warmup_batches * p.batch);
  r.counters["payload_mismatch"] = acc == expected_acc(p) ? 0 : 1;
  r.counters["start_skew_ns"] = gate.start_skew_ns();
  r.counters["ctx_voluntary_a"] = a.voluntary;
  r.counters["ctx_voluntary_b"] = b.voluntary;
  r.counters["ctx_involuntary_a"] = a.involuntary;
  r.counters["ctx_involuntary_b"] = b.involuntary;
}

template <class Token>
std::expected<Run, std::string> pingpong_threads(const PingPongParams& p, std::string_view primitive) {
  Gate gate{2, p.hold};
  Shared<Token> sh;
  Run r;
  std::uint64_t acc = 0, served = 0;
  CtxSwitches ca, cb;
  std::string error_a, error_b;
  const int cpu_a = p.cpus.empty() ? -1 : p.cpus[0];
  const int cpu_b = p.cpus.size() < 2 ? -1 : p.cpus[1];
  std::jthread b{[&](const std::stop_token& stop) {
    try {
      gate.worker_ready(cpu_b, "pong");
      const CtxSwitches c0 = thread_ctx_switches();
      for (;;) {
        sh.ping.wait();
        if (stop.stop_requested()) break;
        sh.slot.v += 1;
        ++served;
        sh.pong.post();
      }
      cb = since(c0);
    } catch (const std::exception& e) {
      error_b = e.what();
    }
  }};
  std::thread a{[&] {
    try {
      gate.worker_ready(cpu_a, "ping");
      const CtxSwitches c0 = thread_ctx_switches();
      const auto turn = [&](std::uint64_t j) {
        sh.slot.v = j;
        sh.ping.post();
        sh.pong.wait();
        acc += sh.slot.v;
      };
      for (std::uint64_t w = 0; w < p.warmup_batches; ++w) {
        for (std::uint64_t j = 0; j < p.batch; ++j) turn(j);
      }
      for (std::uint64_t done = 0; done < p.rounds; done += p.batch) {
        const std::int64_t t0 = now_ns();
        for (std::uint64_t j = 0; j < p.batch; ++j) turn(j);
        r.samples.push_back(positive((now_ns() - t0) / static_cast<std::int64_t>(p.batch)));
      }
      ca = since(c0);
    } catch (const std::exception& e) {
      error_a = e.what();
    }
    b.request_stop();
    sh.ping.post();
  }};
  gate.release();
  a.join();
  b.join();
  if (auto pin = gate.error()) return std::unexpected(*pin);
  if (!error_a.empty() || !error_b.empty()) return std::unexpected(error_a + error_b);
  finish_pingpong(r, p, acc, served, ca, cb, gate);
  r.notes = std::format("pingpong; model=os-thread (jthread and stop_token, {}); rounds={}; batch={}; sample=batch time / batch", primitive,
                        p.rounds, p.batch);
  return r;
}

std::expected<Run, std::string> pingpong_fibers(const PingPongParams& p) {
  Gate gate{1, p.hold};
  Run r;
  std::uint64_t acc = 0, served = 0;
  CtxSwitches ca;
  const int cpu = p.cpus.empty() ? -1 : p.cpus[0];
  auto ran = on_worker(gate, cpu, "fibers", [&] {
    boost::fibers::buffered_channel<std::uint64_t> ping{2}, pong{2};
    boost::context::protected_fixedsize_stack stack{kFiberStackBytes};
    boost::fibers::fiber pong_side{std::allocator_arg, stack, [&] {
      std::uint64_t v = 0;
      while (ping.pop(v) == boost::fibers::channel_op_status::success) {
        ++served;
        pong.push(v + 1);
      }
    }};
    const CtxSwitches c0 = thread_ctx_switches();
    const auto turn = [&](std::uint64_t j) {
      std::uint64_t v = 0;
      ping.push(j);
      pong.pop(v);
      acc += v;
    };
    for (std::uint64_t w = 0; w < p.warmup_batches; ++w) {
      for (std::uint64_t j = 0; j < p.batch; ++j) turn(j);
    }
    for (std::uint64_t done = 0; done < p.rounds; done += p.batch) {
      const std::int64_t t0 = now_ns();
      for (std::uint64_t j = 0; j < p.batch; ++j) turn(j);
      r.samples.push_back(positive((now_ns() - t0) / static_cast<std::int64_t>(p.batch)));
    }
    ca = since(c0);
    ping.close();
    pong_side.join();
  });
  if (!ran) return std::unexpected(ran.error());
  finish_pingpong(r, p, acc, served, ca, CtxSwitches{}, gate);
  r.notes = std::format("pingpong; model=fiber (two fibers, one thread, buffered_channel); rounds={}; batch={}; sample=batch time / batch", p.rounds, p.batch);
  return r;
}

Task<> ping_side(PaddedSlot& slot, const PingPongParams& p, Run& r, std::uint64_t& acc, std::coroutine_handle<>& self,
                 std::coroutine_handle<>& peer) {
  const auto turn = [&](std::uint64_t j) -> Transfer {
    slot.v = j;
    return Transfer{self, peer};
  };
  for (std::uint64_t w = 0; w < p.warmup_batches; ++w) {
    for (std::uint64_t j = 0; j < p.batch; ++j) {
      co_await turn(j);
      acc += slot.v;
    }
  }
  for (std::uint64_t done = 0; done < p.rounds; done += p.batch) {
    const std::int64_t t0 = now_ns();
    for (std::uint64_t j = 0; j < p.batch; ++j) {
      co_await turn(j);
      acc += slot.v;
    }
    r.samples.push_back(positive((now_ns() - t0) / static_cast<std::int64_t>(p.batch)));
  }
}

Task<> pong_side(PaddedSlot& slot, std::uint64_t& served, std::coroutine_handle<>& self, std::coroutine_handle<>& peer) {
  for (;;) {
    slot.v += 1;
    ++served;
    co_await Transfer{self, peer};
  }
}

std::expected<Run, std::string> pingpong_coroutines(const PingPongParams& p) {
  Gate gate{1, p.hold};
  PaddedSlot slot;
  Run r;
  std::uint64_t acc = 0, served = 0;
  CtxSwitches ca;
  const int cpu = p.cpus.empty() ? -1 : p.cpus[0];
  FrameSnapshot frames{};
  auto ran = on_worker(gate, cpu, "coroutines", [&] {
    std::coroutine_handle<> ha, hb;
    const FrameSnapshot f0 = frame_snapshot();
    Task<> b = pong_side(slot, served, hb, ha);
    hb = b.handle();  // not started: A's first Transfer resumes it from its initial suspend point
    Task<> a = ping_side(slot, p, r, acc, ha, hb);
    const CtxSwitches c0 = thread_ctx_switches();
    a.start();  // runs every round trip by symmetric transfer and returns when A finishes
    ca = since(c0);
    a.result();
    const FrameSnapshot f1 = frame_snapshot();
    frames = {f1.allocations - f0.allocations, 0, f1.bytes - f0.bytes};
  });
  if (!ran) return std::unexpected(ran.error());
  finish_pingpong(r, p, acc, served, ca, CtxSwitches{}, gate);
  r.counters["frame_allocations"] = static_cast<std::int64_t>(frames.allocations);
  r.counters["frame_bytes_total"] = static_cast<std::int64_t>(frames.bytes);
  r.notes = std::format("pingpong; model=coroutine (Task<T>, symmetric transfer); rounds={}; batch={}; sample=batch time / batch", p.rounds, p.batch);
  return r;
}

}  // namespace

std::expected<Run, std::string> run_pingpong(Variant v, const PingPongParams& p) {
  if (p.batch == 0 || p.rounds == 0 || p.rounds % p.batch != 0) return std::unexpected("--rounds must be a positive multiple of --batch");
  const std::size_t need = v == Variant::os_thread ? 2 : 1;
  if (p.handoff != "condvar" && p.handoff != "semaphore") return std::unexpected("--handoff: condvar | semaphore");
  if (!p.cpus.empty() && p.cpus.size() < need) return std::unexpected(std::format("--cpus needs {} CPUs for {}", need, name_of(v)));
  try {
    switch (v) {
      case Variant::os_thread:
        return p.handoff == "semaphore" ? pingpong_threads<SemaphoreToken>(p, "binary_semaphore")
                                        : pingpong_threads<CondvarToken>(p, "condition_variable");
      case Variant::fiber: return pingpong_fibers(p);
      case Variant::coroutine: return pingpong_coroutines(p);
    }
  } catch (const std::exception& e) {
    return std::unexpected(e.what());
  }
  return std::unexpected("unknown variant");
}

// ---- (c) neighbours --------------------------------------------------------------------------------------------------

namespace {

struct NeighbourPlan {
  std::int64_t epoch = 0;
  std::int64_t period_ns = 0;
  std::int64_t stagger_ns = 0;
  std::size_t iterations = 0;
  [[nodiscard]] std::int64_t deadline(std::size_t task, std::size_t k) const {
    return epoch + static_cast<std::int64_t>(k) * period_ns + static_cast<std::int64_t>(task) * stagger_ns;
  }
};

NeighbourPlan plan_for(const NeighbourParams& p) {
  const std::int64_t period = ns_of(p.period);
  return {now_ns() + ns_of(500ms), period, period / static_cast<std::int64_t>(p.tasks), p.iterations};
}

bool blocks_now(const NeighbourParams& p, std::size_t task, std::size_t k) { return p.blocking_call && task == 0 && k % 10 == 9; }

void finish_neighbours(Run& r, const NeighbourParams& p, std::vector<std::int64_t>&& lateness, std::size_t late_starts,
                       const char* model) {
  r.samples = std::move(lateness);
  r.counters["tasks"] = static_cast<std::int64_t>(p.tasks);
  r.counters["iterations"] = static_cast<std::int64_t>(p.iterations);
  r.counters["late_starts"] = static_cast<std::int64_t>(late_starts);
  r.counters["blocking_calls"] = p.blocking_call ? static_cast<std::int64_t>(p.iterations / 10) : 0;
  r.counters["blocking_call_us"] = p.blocking_call ? p.block.count() : 0;
  r.notes = std::format("neighbours; model={}; tasks={}; iterations={}; period_us={}; blocking_call={}; sample=wake lateness against the task's deadline",
                        model, p.tasks, p.iterations, p.period.count(), p.blocking_call);
}

std::expected<Run, std::string> neighbours_threads(const NeighbourParams& p) {
  Gate gate{0, p.hold};
  gate.release();
  const NeighbourPlan plan = plan_for(p);
  std::vector<std::int64_t> lateness(p.tasks * p.iterations, 1);
  std::vector<char> late(p.tasks, 0);
  {
    std::vector<std::jthread> threads;
    threads.reserve(p.tasks);
    for (std::size_t i = 0; i < p.tasks; ++i) {
      threads.emplace_back([&, i] {
        late[i] = now_ns() >= plan.deadline(i, 0);
        for (std::size_t k = 0; k < plan.iterations; ++k) {
          const std::int64_t d = plan.deadline(i, k);
          std::this_thread::sleep_until(at(d));
          lateness[i * plan.iterations + k] = positive(now_ns() - d);
        }
      });
    }
  }
  Run r;
  finish_neighbours(r, p, std::move(lateness), static_cast<std::size_t>(std::ranges::count(late, 1)), "os-thread");
  return r;
}

std::expected<Run, std::string> neighbours_fibers(const NeighbourParams& p) {
  Gate gate{1, p.hold};
  std::vector<std::int64_t> lateness(p.tasks * p.iterations, 1);
  std::vector<char> late(p.tasks, 0);
  auto ran = on_worker(gate, p.cpu, "fibers", [&] {
    const NeighbourPlan plan = plan_for(p);
    boost::context::protected_fixedsize_stack stack{kFiberStackBytes};
    std::vector<boost::fibers::fiber> fibers;
    fibers.reserve(p.tasks);
    for (std::size_t i = 0; i < p.tasks; ++i) {
      fibers.emplace_back(std::allocator_arg, stack, [&, i] {
        late[i] = now_ns() >= plan.deadline(i, 0);
        for (std::size_t k = 0; k < plan.iterations; ++k) {
          const std::int64_t d = plan.deadline(i, k);
          boost::this_fiber::sleep_until(at(d));
          lateness[i * plan.iterations + k] = positive(now_ns() - d);
          // The defect: a blocking call inside a fiber blocks the whole OS thread, so every fiber on it waits.
          if (blocks_now(p, i, k)) std::this_thread::sleep_for(p.block);
        }
      });
    }
    for (auto& f : fibers) f.join();
  });
  if (!ran) return std::unexpected(ran.error());
  Run r;
  r.cpus = gate.cpus();
  finish_neighbours(r, p, std::move(lateness), static_cast<std::size_t>(std::ranges::count(late, 1)), "fiber");
  return r;
}

asio::awaitable<void> neighbour(NeighbourPlan plan, std::size_t task, std::int64_t* out, char* late) {
  asio::steady_timer timer{co_await asio::this_coro::executor};
  *late = now_ns() >= plan.deadline(task, 0);
  for (std::size_t k = 0; k < plan.iterations; ++k) {
    const std::int64_t d = plan.deadline(task, k);
    timer.expires_at(at(d));
    co_await timer.async_wait(asio::use_awaitable);
    out[k] = positive(now_ns() - d);
  }
}

std::expected<Run, std::string> neighbours_coroutines(const NeighbourParams& p) {
  Gate gate{1, p.hold};
  std::vector<std::int64_t> lateness(p.tasks * p.iterations, 1);
  std::vector<char> late(p.tasks, 0);
  auto ran = on_worker(gate, p.cpu, "coroutines", [&] {
    asio::io_context ctx{1};
    const NeighbourPlan plan = plan_for(p);
    for (std::size_t i = 0; i < p.tasks; ++i) {
      asio::co_spawn(ctx, neighbour(plan, i, &lateness[i * plan.iterations], &late[i]), asio::detached);
    }
    ctx.run();
  });
  if (!ran) return std::unexpected(ran.error());
  Run r;
  r.cpus = gate.cpus();
  finish_neighbours(r, p, std::move(lateness), static_cast<std::size_t>(std::ranges::count(late, 1)), "coroutine");
  return r;
}

}  // namespace

std::expected<Run, std::string> run_neighbours(Variant v, const NeighbourParams& p) {
  if (p.tasks == 0 || p.iterations == 0) return std::unexpected("--tasks and --iterations must be at least 1");
  if (p.blocking_call && v != Variant::fiber) return std::unexpected("the blocking call is defined for the fiber variant only");
  try {
    switch (v) {
      case Variant::os_thread: return neighbours_threads(p);
      case Variant::fiber: return neighbours_fibers(p);
      case Variant::coroutine: return neighbours_coroutines(p);
    }
  } catch (const std::exception& e) {
    return std::unexpected(e.what());
  }
  return std::unexpected("unknown variant");
}

}  // namespace lowlat::tasks
