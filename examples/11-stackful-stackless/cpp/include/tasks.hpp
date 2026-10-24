// Ch11 wiring skeleton: one stackful and one stackless task, and a std::generator of parcel ids.
#pragma once

#include <generator>

namespace lowlat::tasks {

// Parcel ids 1..n, produced lazily.
std::generator<int> parcel_ids(int n);

// Runs one Boost.Fiber that returns `value`, and waits for it.
int run_one_fiber(int value);

// Runs one Asio awaitable through co_spawn on a private io_context and returns its result.
int run_one_awaitable(int value);

}  // namespace lowlat::tasks
