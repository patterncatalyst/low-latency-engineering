# Ch7 C++ lane (07-offheap-lockfree). Auto-discovered by examples/CMakeLists.txt.
# Header-only SPSC ring over std::atomic, and the hand-off consumer built on it.
add_library(lowlat_offheap_lockfree INTERFACE)
add_library(lowlat::offheap_lockfree ALIAS lowlat_offheap_lockfree)
target_include_directories(lowlat_offheap_lockfree INTERFACE include)
target_link_libraries(lowlat_offheap_lockfree INTERFACE lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_offheap_lockfree INTERFACE cxx_std_23)

add_executable(offheap-handoff src/handoff.cpp)
target_link_libraries(offheap-handoff PRIVATE lowlat::offheap_lockfree lowlat::warnings)

if(BUILD_TESTING)
  add_executable(offheap-lockfree-test tests/spsc_ring_test.cpp)
  target_link_libraries(offheap-lockfree-test PRIVATE lowlat::offheap_lockfree GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(offheap-lockfree-test)
endif()
