# Ch10 C++ lane (10-lockfree-waitfree). Auto-discovered by examples/CMakeLists.txt.
#
# lowlat::lockfree is the library behind the lane: the three claim primitives, the multi-producer log,
# the induction-gap litmus test, the seqlock and the thread-placement helpers. The claim, litmus and
# seqlock runs share one executable (lockfree-bench); the line run, the store-cost benchmark and the
# tests are separate.
add_library(lowlat_lockfree STATIC src/placement.cpp)
add_library(lowlat::lockfree ALIAS lowlat_lockfree)
target_include_directories(lowlat_lockfree PUBLIC include)
target_link_libraries(lowlat_lockfree PUBLIC lowlat::line_consumer lowlat::line lowlat::measure lowlat::proto)
target_compile_features(lowlat_lockfree PUBLIC cxx_std_23)
target_link_libraries(lowlat_lockfree PRIVATE lowlat::warnings)

add_executable(lockfree-bench src/bench_main.cpp)
target_link_libraries(lockfree-bench PRIVATE lowlat::lockfree lowlat::warnings)

add_executable(lockfree-line src/line_main.cpp)
target_link_libraries(lockfree-line PRIVATE lowlat::lockfree lowlat::warnings)

add_executable(lockfree-store-bench src/store_bench.cpp)
target_link_libraries(lockfree-store-bench PRIVATE benchmark::benchmark lowlat::warnings)

if(BUILD_TESTING)
  add_executable(lockfree-test tests/lockfree_test.cpp)
  target_link_libraries(lockfree-test PRIVATE lowlat::lockfree GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(lockfree-test)
endif()
