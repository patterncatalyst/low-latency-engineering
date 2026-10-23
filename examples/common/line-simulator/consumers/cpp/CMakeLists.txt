# C++ line consumer: receives ParcelEvent datagrams, records latency against
# the intended emit time (see ../README.md).
add_library(lowlat_line_consumer STATIC src/consumer.cpp)
add_library(lowlat::line_consumer ALIAS lowlat_line_consumer)
target_include_directories(lowlat_line_consumer PUBLIC include)
target_link_libraries(lowlat_line_consumer PUBLIC lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_line_consumer PUBLIC cxx_std_23)
target_link_libraries(lowlat_line_consumer PRIVATE lowlat::warnings)

add_executable(line-consumer src/main.cpp)
target_link_libraries(line-consumer PRIVATE lowlat::line_consumer lowlat::warnings)

if(BUILD_TESTING)
  add_executable(line-consumer-test tests/consumer_test.cpp)
  target_link_libraries(line-consumer-test PRIVATE lowlat::line_consumer GTest::gtest_main lowlat::warnings)
  target_compile_definitions(line-consumer-test PRIVATE
    LOWLAT_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../measure-fixtures")
  include(GoogleTest)
  gtest_discover_tests(line-consumer-test)
endif()
