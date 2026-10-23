# Ch10 C++ lane (10-lockfree-waitfree). Auto-discovered by examples/CMakeLists.txt.
# Wiring only (S4): a header-only claim counter. S6 adds the mutex, CAS-loop and fetch-add claims,
# the litmus test and the seqlock.
add_library(lowlat_lockfree INTERFACE)
add_library(lowlat::lockfree ALIAS lowlat_lockfree)
target_include_directories(lowlat_lockfree INTERFACE include)
target_compile_features(lowlat_lockfree INTERFACE cxx_std_23)

if(BUILD_TESTING)
  add_executable(lockfree-test tests/wiring_test.cpp)
  target_link_libraries(lockfree-test PRIVATE lowlat::lockfree GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(lockfree-test)
endif()
