#include "tasks.hpp"

#include <boost/asio/awaitable.hpp>
#include <boost/asio/co_spawn.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/use_future.hpp>
#include <boost/fiber/future.hpp>

namespace lowlat::tasks {

std::generator<int> parcel_ids(int n) {
  for (int id = 1; id <= n; ++id) {
    co_yield id;
  }
}

int run_one_fiber(int value) {
  boost::fibers::future<int> done = boost::fibers::async([value] { return value; });
  return done.get();
}

namespace {
boost::asio::awaitable<int> answer(int value) { co_return value; }
}  // namespace

int run_one_awaitable(int value) {
  boost::asio::io_context ctx;
  auto result = boost::asio::co_spawn(ctx, answer(value), boost::asio::use_future);
  ctx.run();
  return result.get();
}

}  // namespace lowlat::tasks
