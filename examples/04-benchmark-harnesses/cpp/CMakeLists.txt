# Ch4 C++ benchmark: Google Benchmark (pinned in cmake/deps.cmake) and a parity test
# against the line-simulator's SSCC reference.
add_executable(check-digit-bench check_digit_bench.cpp)
target_link_libraries(check-digit-bench PRIVATE benchmark::benchmark)
target_compile_features(check-digit-bench PRIVATE cxx_std_23)
target_link_libraries(check-digit-bench PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(check-digit-test check_digit_test.cpp)
  target_link_libraries(check-digit-test PRIVATE lowlat::line GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(check-digit-test)
endif()
