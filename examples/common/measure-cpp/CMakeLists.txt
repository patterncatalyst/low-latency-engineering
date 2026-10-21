# C++ measurement kit (see ../MEASUREMENT.md): HdrHistogram_c + nlohmann/json.
add_library(lowlat_measure STATIC src/recorder.cpp)
add_library(lowlat::measure ALIAS lowlat_measure)
target_include_directories(lowlat_measure PUBLIC include)
target_link_libraries(lowlat_measure PUBLIC hdr_histogram_static nlohmann_json::nlohmann_json)
target_compile_features(lowlat_measure PUBLIC cxx_std_23)
target_compile_options(lowlat_measure PRIVATE -Wall -Wextra -Wpedantic)

# Recorded in the report's build.flags: build type plus the flags that apply to it.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _lowlat_bt)
string(STRIP "${CMAKE_BUILD_TYPE}: ${CMAKE_CXX_FLAGS} ${CMAKE_CXX_FLAGS_${_lowlat_bt}}" _lowlat_flags)
string(REGEX REPLACE " +" " " _lowlat_flags "${_lowlat_flags}")
target_compile_definitions(lowlat_measure PRIVATE LOWLAT_MEASURE_BUILD_FLAGS="${_lowlat_flags}")

add_executable(measure-test tests/recorder_test.cpp)
target_link_libraries(measure-test PRIVATE lowlat::measure GTest::gtest_main)
target_compile_options(measure-test PRIVATE -Wall -Wextra -Wpedantic)
# Absolute source path, so the golden report lands in the tree whatever the cwd.
target_compile_definitions(measure-test PRIVATE
  LOWLAT_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../measure-fixtures")
include(GoogleTest)
gtest_discover_tests(measure-test)
