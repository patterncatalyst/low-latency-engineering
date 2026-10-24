# Ch9 C++ lane (09-eliminating-work). Auto-discovered by examples/CMakeLists.txt.
#   lowlat::eliminating_work   header-only tracker, records and counters; links absl::flat_hash_map from the
#                              pinned prefix (find_package(absl) in the root CMakeLists.txt)
#   alloc-counter              replaces the global operator new to count per thread (linked by the
#                              executables and the test that read exact allocation counts)
#   tracker-bench              insert / lookup / sweep microbenchmarks (one latency report per run)
#   counters-bench             five camera threads' counters: adjacent against padded
#   eliminating-line           the line consumer with the hub tracker as its handler
add_library(lowlat_eliminating_work INTERFACE)
add_library(lowlat::eliminating_work ALIAS lowlat_eliminating_work)
target_include_directories(lowlat_eliminating_work INTERFACE include)
target_link_libraries(lowlat_eliminating_work INTERFACE absl::flat_hash_map lowlat::line lowlat::measure)
target_compile_features(lowlat_eliminating_work INTERFACE cxx_std_23)

add_library(lowlat_alloc_counter STATIC src/alloc_counter.cpp)
add_library(lowlat::alloc_counter ALIAS lowlat_alloc_counter)
target_include_directories(lowlat_alloc_counter PUBLIC include)
target_compile_features(lowlat_alloc_counter PUBLIC cxx_std_23)
target_link_libraries(lowlat_alloc_counter PRIVATE lowlat::warnings)

add_executable(tracker-bench src/tracker_bench.cpp)
target_link_libraries(tracker-bench PRIVATE lowlat::eliminating_work lowlat::alloc_counter lowlat::warnings)

add_executable(counters-bench src/counters_bench.cpp)
target_link_libraries(counters-bench PRIVATE lowlat::eliminating_work lowlat::warnings)

add_executable(eliminating-line src/line_consumer.cpp)
target_link_libraries(eliminating-line PRIVATE lowlat::eliminating_work lowlat::line_consumer lowlat::alloc_counter
                                               lowlat::warnings)

if(BUILD_TESTING)
  add_executable(eliminating-work-test tests/tracker_test.cpp)
  target_link_libraries(eliminating-work-test PRIVATE lowlat::eliminating_work lowlat::alloc_counter GTest::gtest_main
                                                     lowlat::warnings)
  target_compile_definitions(eliminating-work-test PRIVATE LOWLAT_FLAT_GOLDEN_DIR="${LOWLAT_FLAT_ROOT}/parcel-v1")
  include(GoogleTest)
  gtest_discover_tests(eliminating-work-test)
endif()
