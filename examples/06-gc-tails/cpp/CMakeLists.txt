# Ch6 C++ lane (06-gc-tails). Auto-discovered by examples/CMakeLists.txt.
# Build skeleton: the example code arrives in a later step.
add_library(lowlat_gc_tails STATIC src/skeleton.cpp)
add_library(lowlat::gc_tails ALIAS lowlat_gc_tails)
target_include_directories(lowlat_gc_tails PUBLIC include)
target_link_libraries(lowlat_gc_tails PUBLIC lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_gc_tails PUBLIC cxx_std_23)
target_link_libraries(lowlat_gc_tails PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(gc-tails-test tests/skeleton_test.cpp)
  target_link_libraries(gc-tails-test PRIVATE lowlat::gc_tails GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(gc-tails-test)
endif()
