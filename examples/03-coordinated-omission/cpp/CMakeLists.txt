# Ch3 coordinated-omission experiment (C++). Auto-discovered by examples/CMakeLists.txt.
add_library(lowlat_co STATIC src/experiment.cpp)
add_library(lowlat::co ALIAS lowlat_co)
target_include_directories(lowlat_co PUBLIC include)
target_link_libraries(lowlat_co PUBLIC lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_co PUBLIC cxx_std_23)
target_link_libraries(lowlat_co PRIVATE lowlat::warnings)

add_executable(co-experiment src/main.cpp)
target_link_libraries(co-experiment PRIVATE lowlat::co lowlat::warnings)

if(BUILD_TESTING)
  add_executable(co-experiment-test tests/experiment_test.cpp)
  target_link_libraries(co-experiment-test PRIVATE lowlat::co GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(co-experiment-test)
endif()
