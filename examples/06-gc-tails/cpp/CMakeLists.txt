# Ch6 C++ lane (06-gc-tails): free-policy contrast on a retired wave of manifest entries.
# Auto-discovered by examples/CMakeLists.txt.
add_library(lowlat_gc_tails STATIC src/tracker.cpp)
add_library(lowlat::gc_tails ALIAS lowlat_gc_tails)
target_include_directories(lowlat_gc_tails PUBLIC include)
target_link_libraries(lowlat_gc_tails PUBLIC lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_gc_tails PUBLIC cxx_std_23)
target_link_libraries(lowlat_gc_tails PRIVATE lowlat::warnings)

add_executable(gc-tails-consumer src/main.cpp)
target_link_libraries(gc-tails-consumer PRIVATE lowlat::gc_tails lowlat::warnings)

if(BUILD_TESTING)
  add_executable(gc-tails-test tests/tracker_test.cpp)
  target_link_libraries(gc-tails-test PRIVATE lowlat::gc_tails GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(gc-tails-test)
endif()
