# Ch5 C++ lane (05-jvm-costs). Auto-discovered by examples/CMakeLists.txt.
#   lowlat::jvm_costs      the tracker (header-only logic, shared by the consumer, the benchmark and the test)
#   jvmcosts-consumer      the line consumer with the tracker as handler (first-window / steady split)
#   jvmcosts-bench         Google Benchmark: value vs --allocating (and pmr, observed)
add_library(lowlat_jvm_costs INTERFACE)
add_library(lowlat::jvm_costs ALIAS lowlat_jvm_costs)
target_include_directories(lowlat_jvm_costs INTERFACE include)
target_link_libraries(lowlat_jvm_costs INTERFACE lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_jvm_costs INTERFACE cxx_std_23)

add_executable(jvmcosts-consumer src/consumer.cpp)
target_link_libraries(jvmcosts-consumer PRIVATE lowlat::jvm_costs lowlat::warnings)

add_executable(jvmcosts-bench src/alloc_bench.cpp)
target_link_libraries(jvmcosts-bench PRIVATE lowlat::jvm_costs benchmark::benchmark lowlat::warnings)

if(BUILD_TESTING)
  add_executable(jvm-costs-test tests/tracker_test.cpp)
  target_link_libraries(jvm-costs-test PRIVATE lowlat::jvm_costs GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(jvm-costs-test)
endif()
