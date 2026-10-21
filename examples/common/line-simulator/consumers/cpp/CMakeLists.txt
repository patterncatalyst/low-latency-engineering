# C++ line consumer: receives ParcelEvent datagrams, records latency against
# the intended emit time (see ../README.md).
add_library(lowlat_line_consumer STATIC src/consumer.cpp)
add_library(lowlat::line_consumer ALIAS lowlat_line_consumer)
target_include_directories(lowlat_line_consumer PUBLIC include)
target_link_libraries(lowlat_line_consumer PUBLIC lowlat::line lowlat::proto lowlat::measure)
target_compile_features(lowlat_line_consumer PUBLIC cxx_std_23)
target_compile_options(lowlat_line_consumer PRIVATE -Wall -Wextra -Wpedantic)

add_executable(line-consumer src/main.cpp)
target_link_libraries(line-consumer PRIVATE lowlat::line_consumer)
target_compile_options(line-consumer PRIVATE -Wall -Wextra -Wpedantic)

add_executable(line-consumer-test tests/consumer_test.cpp)
target_link_libraries(line-consumer-test PRIVATE lowlat::line_consumer GTest::gtest_main)
target_compile_options(line-consumer-test PRIVATE -Wall -Wextra -Wpedantic)
include(GoogleTest)
gtest_discover_tests(line-consumer-test)
