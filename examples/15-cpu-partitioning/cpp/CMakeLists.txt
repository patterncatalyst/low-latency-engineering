# Ch15 C++ lane (15-cpu-partitioning). Auto-discovered by examples/CMakeLists.txt.
# placement-probe: where a busy thread runs and how often the kernel took the CPU from it.
add_library(lowlat_placement STATIC src/placement.cpp)
add_library(lowlat::placement ALIAS lowlat_placement)
target_include_directories(lowlat_placement PUBLIC include)
target_compile_features(lowlat_placement PUBLIC cxx_std_23)
target_link_libraries(lowlat_placement PUBLIC lowlat::cyclic nlohmann_json::nlohmann_json)
target_link_libraries(lowlat_placement PRIVATE lowlat::warnings)

add_executable(placement-probe src/placement_probe_main.cpp)
target_link_libraries(placement-probe PRIVATE lowlat::placement lowlat::warnings)

if(BUILD_TESTING)
  add_executable(placement-test tests/placement_test.cpp)
  target_link_libraries(placement-test PRIVATE lowlat::placement GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(placement-test)

  add_test(NAME placement-probe-cli COMMAND placement-probe --busy-ms 20)
  set_tests_properties(placement-probe-cli PROPERTIES PASS_REGULAR_EXPRESSION "lowlat-placement-probe/1")
endif()
