# Ch11 C++ lane (11-stackful-stackless). Auto-discovered by examples/CMakeLists.txt.
# Boost 1.92.0 (asio, fiber, context) comes from cmake/deps.cmake.
#
# lowlat::tasks is the library behind the lane: the three execution models (OS threads, Boost.Fiber, Asio
# coroutines), the three workloads (parked tasks, ping-pong, neighbours), the counted-frame Task<T> and the
# thread-placement helpers. tasks-bench runs the micro workloads, tasks-line the line run.
add_library(lowlat_tasks STATIC src/placement.cpp src/procinfo.cpp src/sink.cpp src/workloads.cpp)
add_library(lowlat::tasks ALIAS lowlat_tasks)
target_include_directories(lowlat_tasks PUBLIC include)
target_compile_features(lowlat_tasks PUBLIC cxx_std_23)
target_link_libraries(lowlat_tasks PUBLIC
  Boost::fiber Boost::context Boost::asio
  lowlat::line_consumer lowlat::line lowlat::measure lowlat::proto)
target_link_libraries(lowlat_tasks PRIVATE lowlat::warnings)

add_executable(tasks-bench src/bench_main.cpp)
target_link_libraries(tasks-bench PRIVATE lowlat::tasks lowlat::warnings)

add_executable(tasks-line src/line_main.cpp)
target_link_libraries(tasks-line PRIVATE lowlat::tasks lowlat::warnings)

if(BUILD_TESTING)
  add_executable(tasks-test tests/tasks_test.cpp)
  target_link_libraries(tasks-test PRIVATE lowlat::tasks GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(tasks-test)
endif()
