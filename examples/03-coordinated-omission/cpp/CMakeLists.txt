# Ch3 coordinated-omission experiment (C++). Auto-discovered by examples/CMakeLists.txt.
add_library(lowlat_co STATIC src/experiment.cpp)
add_library(lowlat::co ALIAS lowlat_co)
target_include_directories(lowlat_co PUBLIC include)
target_link_libraries(lowlat_co PUBLIC lowlat::line_consumer lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_co PUBLIC cxx_std_23)
target_compile_options(lowlat_co PRIVATE -Wall -Wextra -Wpedantic)

add_executable(co-experiment src/main.cpp)
target_link_libraries(co-experiment PRIVATE lowlat::co)
target_compile_options(co-experiment PRIVATE -Wall -Wextra -Wpedantic)

add_executable(co-experiment-test tests/experiment_test.cpp)
target_link_libraries(co-experiment-test PRIVATE lowlat::co GTest::gtest_main)
target_compile_options(co-experiment-test PRIVATE -Wall -Wextra -Wpedantic)
include(GoogleTest)
gtest_discover_tests(co-experiment-test)
