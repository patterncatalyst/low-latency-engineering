# Reference parcel-line simulator (open loop, UDP, protobuf ParcelEvent).
add_library(lowlat_line STATIC src/sscc.cpp src/config.cpp src/simulator.cpp)
add_library(lowlat::line ALIAS lowlat_line)
target_include_directories(lowlat_line PUBLIC include)
target_link_libraries(lowlat_line PUBLIC lowlat::proto lowlat::measure)
target_compile_features(lowlat_line PUBLIC cxx_std_23)
target_link_libraries(lowlat_line PRIVATE lowlat::warnings)

add_executable(line-simulator src/main.cpp)
target_link_libraries(line-simulator PRIVATE lowlat::line lowlat::warnings)

if(BUILD_TESTING)
  add_executable(line-simulator-test tests/line_test.cpp)
  target_link_libraries(line-simulator-test PRIVATE lowlat::line GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(line-simulator-test)
endif()

add_subdirectory(consumers)
