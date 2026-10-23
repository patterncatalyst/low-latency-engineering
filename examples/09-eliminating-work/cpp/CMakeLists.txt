# Ch9 C++ lane (09-eliminating-work). Auto-discovered by examples/CMakeLists.txt.
# Wiring only (S4): the library links absl::flat_hash_map from the pinned prefix (find_package(absl)
# in the root CMakeLists.txt). S5 adds the node-vs-flat, hot/cold and false-sharing variants.
add_library(lowlat_eliminating_work STATIC src/wiring.cpp)
add_library(lowlat::eliminating_work ALIAS lowlat_eliminating_work)
target_include_directories(lowlat_eliminating_work PUBLIC include)
target_link_libraries(lowlat_eliminating_work PUBLIC absl::flat_hash_map)
target_compile_features(lowlat_eliminating_work PUBLIC cxx_std_23)
target_link_libraries(lowlat_eliminating_work PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(eliminating-work-test tests/wiring_test.cpp)
  target_link_libraries(eliminating-work-test PRIVATE lowlat::eliminating_work GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(eliminating-work-test)
endif()
