#include "lowlat/cyclic/probe.hpp"

#include <sched.h>
#include <sys/mman.h>

#include <algorithm>
#include <cerrno>
#include <format>
#include <stdexcept>
#include <system_error>

#include "lowlat/measure/runtime.hpp"

namespace lowlat::cyclic {
namespace {

using std::chrono::nanoseconds;

std::string errno_text(const char* call, int err) {
  return std::format("{}: {}", call, std::system_category().message(err));
}

}  // namespace

Advance advance(Mono deadline, Mono now, nanoseconds interval) {
  Mono next = deadline + interval;
  std::uint64_t skipped = 0;
  if (next < now) {
    // Whole intervals to step over, in one division instead of a loop that a long stall would spin.
    // ceil((now - next) / interval): a grid point exactly at `now` is not skipped.
    const auto behind = (now - next + interval - nanoseconds{1}) / interval;
    next += behind * interval;
    skipped = static_cast<std::uint64_t>(behind);
  }
  return {next, skipped};
}

std::uint64_t missed_in_window(std::uint64_t skipped, Mono first_skipped, Mono end, nanoseconds interval) {
  if (first_skipped > end) return 0;
  const auto inside = static_cast<std::uint64_t>((end - first_skipped) / interval) + 1;
  return std::min(skipped, inside);
}

timespec to_timespec(Mono t) {
  const auto secs = std::chrono::duration_cast<std::chrono::seconds>(t);
  return {.tv_sec = static_cast<time_t>(secs.count()), .tv_nsec = static_cast<long>((t - secs).count())};
}

Result validate(const Config& config) {
  if (config.interval <= nanoseconds::zero()) return std::unexpected{"interval must be positive"};
  if (config.duration < config.interval) return std::unexpected{"duration must cover at least one interval"};
  if (config.fifo_priority < 0 || config.fifo_priority > 99) return std::unexpected{"priority must be 0..99"};
  if (config.cpu < -1) return std::unexpected{"cpu must be -1 or a CPU number"};
  return {};
}

Result pin_to_cpu(int cpu) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  if (sched_setaffinity(0, sizeof set, &set) != 0) return std::unexpected{errno_text("sched_setaffinity", errno)};
  return {};
}

Result set_fifo(int priority) {
  const sched_param param{.sched_priority = priority};
  // pid 0 is the calling thread on Linux, so the policy applies to this thread only.
  if (sched_setscheduler(0, SCHED_FIFO, &param) != 0) return std::unexpected{errno_text("sched_setscheduler", errno)};
  return {};
}

Result lock_all_memory() {
  if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) return std::unexpected{errno_text("mlockall", errno)};
  return {};
}

Mono now() {
  timespec ts{};
  // clock_gettime, not std::chrono::steady_clock: the deadline and the sleep must name the same clock id explicitly.
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) throw std::system_error(errno, std::system_category(), "clock_gettime");
  return std::chrono::seconds{ts.tv_sec} + nanoseconds{ts.tv_nsec};
}

std::expected<Outcome, std::string> run(const Config& config, measure::Recorder& recorder) {
  if (auto ok = validate(config); !ok) return std::unexpected{ok.error()};
  if (config.lock_memory) {
    if (auto ok = lock_all_memory(); !ok) return std::unexpected{ok.error()};
  }
  if (config.cpu >= 0) {
    if (auto ok = pin_to_cpu(config.cpu); !ok) return std::unexpected{ok.error()};
  }
  if (config.fifo_priority > 0) {
    if (auto ok = set_fifo(config.fifo_priority); !ok) return std::unexpected{ok.error()};
  }

  const Mono start = now();
  const Mono end = start + config.duration;
  Outcome outcome;
  Mono deadline = start + config.interval;
  while (deadline <= end) {
    const timespec target = to_timespec(deadline);
    int rc = 0;
    // clock_nanosleep returns the error number itself (it does not set errno); EINTR resumes the same deadline.
    do {
      rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &target, nullptr);
    } while (rc == EINTR);
    if (rc != 0) return std::unexpected{errno_text("clock_nanosleep", rc)};
    const Mono woke = now();
    recorder.record(std::max<std::int64_t>(0, (woke - deadline).count()));
    ++outcome.samples;
    const Advance next = advance(deadline, woke, config.interval);
    outcome.missed_periods += missed_in_window(next.skipped, deadline + config.interval, end, config.interval);
    deadline = next.deadline;
  }
  return outcome;
}

nlohmann::json runtime_block(const Config& config, const Outcome& outcome, const std::string& environment_kind,
                             const std::string& guest_profile) {
  nlohmann::json runtime = nlohmann::json::object();
  if (config.cpu >= 0) {
    const int cpus[] = {config.cpu};
    // One CPU: trivially on a distinct core and with no sibling pinned beside it.
    runtime["placement"] = measure::placement(cpus, true, false);
  }
  runtime["counters"] = measure::counters({{"samples", static_cast<std::int64_t>(outcome.samples)},
                                           {"missed_periods", static_cast<std::int64_t>(outcome.missed_periods)}});
  if (!environment_kind.empty()) {
    // The enum's JSON conversion falls back to the first value on an unknown string; refuse that here.
    if (environment_kind != "host" && environment_kind != "vm" && environment_kind != "container") {
      throw std::invalid_argument(std::format("environment must be host, vm or container, got '{}'", environment_kind));
    }
    const auto kind = nlohmann::json(environment_kind).get<measure::EnvKind>();
    runtime["environment"] =
        measure::environment(kind, guest_profile.empty() ? std::nullopt : std::optional<std::string>{guest_profile});
  }
  return runtime;
}

}  // namespace lowlat::cyclic
