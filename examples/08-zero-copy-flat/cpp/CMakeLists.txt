# Ch8 C++ lane (08-zero-copy-flat). Auto-discovered by examples/CMakeLists.txt.
# Build skeleton: the example code arrives in a later step.
add_library(lowlat_zero_copy_flat STATIC src/skeleton.cpp)
add_library(lowlat::zero_copy_flat ALIAS lowlat_zero_copy_flat)
target_include_directories(lowlat_zero_copy_flat PUBLIC include)
target_link_libraries(lowlat_zero_copy_flat PUBLIC lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_zero_copy_flat PUBLIC cxx_std_23)
target_link_libraries(lowlat_zero_copy_flat PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(zero-copy-flat-test tests/skeleton_test.cpp)
  target_link_libraries(zero-copy-flat-test PRIVATE lowlat::zero_copy_flat GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(zero-copy-flat-test)
endif()
