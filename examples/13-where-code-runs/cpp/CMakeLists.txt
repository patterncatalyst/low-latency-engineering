# Ch13 C++ lane (13-where-code-runs), wiring skeleton. Auto-discovered by examples/CMakeLists.txt.
add_library(lowlat_place STATIC src/cgroup_probe.cpp)
add_library(lowlat::place ALIAS lowlat_place)
target_include_directories(lowlat_place PUBLIC include)
target_compile_features(lowlat_place PUBLIC cxx_std_23)
target_link_libraries(lowlat_place PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(place-test tests/cgroup_probe_test.cpp)
  target_link_libraries(place-test PRIVATE lowlat::place GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(place-test)
endif()
