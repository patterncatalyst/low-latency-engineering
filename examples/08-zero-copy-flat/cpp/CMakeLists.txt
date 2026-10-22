# Ch8 C++ lane (08-zero-copy-flat). Auto-discovered by examples/CMakeLists.txt.
# Header-only decode variants over std::span<const std::byte>, the flat-vs-pointer table, a golden
# dump tool and a Google Benchmark executable (pinned in cmake/deps.cmake).
add_library(lowlat_zero_copy_flat STATIC src/table.cpp)
add_library(lowlat::zero_copy_flat ALIAS lowlat_zero_copy_flat)
target_include_directories(lowlat_zero_copy_flat PUBLIC include)
target_link_libraries(lowlat_zero_copy_flat PUBLIC lowlat::flat_parcel_v1 lowlat::line_consumer lowlat::measure)
target_compile_features(lowlat_zero_copy_flat PUBLIC cxx_std_23)
target_link_libraries(lowlat_zero_copy_flat PRIVATE lowlat::warnings)

add_executable(flat-dump src/flat_dump.cpp)
target_link_libraries(flat-dump PRIVATE lowlat::zero_copy_flat lowlat::warnings)

add_executable(flat-bench src/flat_bench.cpp)
target_link_libraries(flat-bench PRIVATE lowlat::zero_copy_flat benchmark::benchmark lowlat::warnings)

if(BUILD_TESTING)
  add_executable(zero-copy-flat-test tests/flat_test.cpp)
  target_link_libraries(zero-copy-flat-test PRIVATE lowlat::zero_copy_flat GTest::gtest_main lowlat::warnings)
  set(_golden_dir "${CMAKE_CURRENT_SOURCE_DIR}/../../../contracts/flat/parcel-v1")
  cmake_path(NORMAL_PATH _golden_dir)
  target_compile_definitions(zero-copy-flat-test PRIVATE LOWLAT_FLAT_GOLDEN_DIR="${_golden_dir}")
  include(GoogleTest)
  gtest_discover_tests(zero-copy-flat-test)
endif()
