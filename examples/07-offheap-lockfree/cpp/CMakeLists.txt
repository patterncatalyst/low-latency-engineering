# Ch7 C++ lane (07-offheap-lockfree). Auto-discovered by examples/CMakeLists.txt.
# Build skeleton: the example code arrives in a later step.
add_library(lowlat_offheap_lockfree STATIC src/skeleton.cpp)
add_library(lowlat::offheap_lockfree ALIAS lowlat_offheap_lockfree)
target_include_directories(lowlat_offheap_lockfree PUBLIC include)
target_link_libraries(lowlat_offheap_lockfree PUBLIC lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_offheap_lockfree PUBLIC cxx_std_23)
target_link_libraries(lowlat_offheap_lockfree PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(offheap-lockfree-test tests/skeleton_test.cpp)
  target_link_libraries(offheap-lockfree-test PRIVATE lowlat::offheap_lockfree GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(offheap-lockfree-test)
endif()
