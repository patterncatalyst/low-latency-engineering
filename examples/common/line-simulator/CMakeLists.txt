# Reference parcel-line simulator (open loop, UDP, protobuf ParcelEvent).
# consumers/ is owned by later steps and is added by them.
add_library(lowlat_line STATIC src/sscc.cpp src/config.cpp src/simulator.cpp)
add_library(lowlat::line ALIAS lowlat_line)
target_include_directories(lowlat_line PUBLIC include)
target_link_libraries(lowlat_line PUBLIC lowlat::proto lowlat::measure)
target_compile_features(lowlat_line PUBLIC cxx_std_23)
target_compile_options(lowlat_line PRIVATE -Wall -Wextra -Wpedantic)

add_executable(line-simulator src/main.cpp)
target_link_libraries(line-simulator PRIVATE lowlat::line)
target_compile_options(line-simulator PRIVATE -Wall -Wextra -Wpedantic)

add_executable(line-simulator-test tests/line_test.cpp)
target_link_libraries(line-simulator-test PRIVATE lowlat::line GTest::gtest_main)
target_compile_options(line-simulator-test PRIVATE -Wall -Wextra -Wpedantic)
include(GoogleTest)
gtest_discover_tests(line-simulator-test)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/consumers/CMakeLists.txt")
  add_subdirectory(consumers)
endif()
