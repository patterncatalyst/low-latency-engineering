# Ch5 C++ lane (05-jvm-costs). Auto-discovered by examples/CMakeLists.txt.
# Build skeleton: the example code arrives in a later step.
add_library(lowlat_jvm_costs STATIC src/skeleton.cpp)
add_library(lowlat::jvm_costs ALIAS lowlat_jvm_costs)
target_include_directories(lowlat_jvm_costs PUBLIC include)
target_link_libraries(lowlat_jvm_costs PUBLIC lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_jvm_costs PUBLIC cxx_std_23)
target_link_libraries(lowlat_jvm_costs PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(jvm-costs-test tests/skeleton_test.cpp)
  target_link_libraries(jvm-costs-test PRIVATE lowlat::jvm_costs GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(jvm-costs-test)
endif()
