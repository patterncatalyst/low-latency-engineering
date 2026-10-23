# Ch7 C++ lane (07-offheap-lockfree). Auto-discovered by examples/CMakeLists.txt.
# Header-only SPSC ring over std::atomic, and the hand-off consumer built on it.
add_library(lowlat_offheap_ring INTERFACE)
add_library(lowlat::offheap_ring ALIAS lowlat_offheap_ring)
target_include_directories(lowlat_offheap_ring INTERFACE include)
target_compile_features(lowlat_offheap_ring INTERFACE cxx_std_23)

# The hand-off (decide thread over the ring) is where the consumer, proto and measure deps start.
add_library(lowlat_offheap_handoff INTERFACE)
add_library(lowlat::offheap_handoff ALIAS lowlat_offheap_handoff)
target_link_libraries(lowlat_offheap_handoff INTERFACE lowlat::offheap_ring lowlat::line_consumer lowlat::line
                      lowlat::proto lowlat::measure)

add_executable(offheap-handoff src/handoff.cpp)
target_link_libraries(offheap-handoff PRIVATE lowlat::offheap_handoff lowlat::warnings)

if(BUILD_TESTING)
  include(GoogleTest)
  add_executable(offheap-lockfree-test tests/spsc_ring_test.cpp)
  target_link_libraries(offheap-lockfree-test PRIVATE lowlat::offheap_ring GTest::gtest_main lowlat::warnings)
  gtest_discover_tests(offheap-lockfree-test)

  add_executable(offheap-handoff-test tests/handoff_test.cpp)
  target_link_libraries(offheap-handoff-test PRIVATE lowlat::offheap_handoff GTest::gtest_main lowlat::warnings)
  gtest_discover_tests(offheap-handoff-test)
endif()
