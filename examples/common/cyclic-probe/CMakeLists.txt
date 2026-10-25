# cyclic-probe: the periodic waker behind chapters 14 and 16 (and Ch15's lane runs). It wakes on an
# absolute CLOCK_MONOTONIC deadline, as cyclictest does, and records actual wake minus intended wake into the
# measurement kit's HdrHistogram wrapper. lowlat::cyclic is the library; cyclic-probe is the command line.
add_library(lowlat_cyclic STATIC src/probe.cpp)
add_library(lowlat::cyclic ALIAS lowlat_cyclic)
target_include_directories(lowlat_cyclic PUBLIC include)
target_compile_features(lowlat_cyclic PUBLIC cxx_std_23)
target_link_libraries(lowlat_cyclic PUBLIC lowlat::measure)
target_link_libraries(lowlat_cyclic PRIVATE lowlat::warnings)

add_executable(cyclic-probe src/main.cpp)
target_link_libraries(cyclic-probe PRIVATE lowlat::cyclic lowlat::warnings)

if(BUILD_TESTING)
  add_executable(cyclic-test tests/probe_test.cpp)
  target_link_libraries(cyclic-test PRIVATE lowlat::cyclic GTest::gtest_main lowlat::warnings)
  target_compile_definitions(cyclic-test PRIVATE
    LOWLAT_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../measure-fixtures")
  include(GoogleTest)
  gtest_discover_tests(cyclic-test)

  # The command line, end to end, with no privilege: SCHED_OTHER, no mlockall, 40 ms at 1 ms.
  add_test(NAME cyclic-probe-cli COMMAND cyclic-probe --interval-us 1000 --duration-ms 40)
  set_tests_properties(cyclic-probe-cli PROPERTIES PASS_REGULAR_EXPRESSION "samples=40")
endif()
