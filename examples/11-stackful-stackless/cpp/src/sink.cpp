#include "lowlat/tasks/sink.hpp"

#include <atomic>

namespace lowlat::tasks {

namespace {
std::atomic<std::uint64_t> g_sink{0};
}

void sink(std::uint64_t value) noexcept { g_sink.fetch_add(value, std::memory_order_relaxed); }

std::uint64_t sink_value() noexcept { return g_sink.load(std::memory_order_relaxed); }

}  // namespace lowlat::tasks
