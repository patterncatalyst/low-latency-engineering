# Ch12 C++ lane (12-io-engines), wiring skeleton. Auto-discovered by examples/CMakeLists.txt.
# liburing 2.15 (lowlat::uring) and Boost.Asio 1.92.0 come from cmake/deps.cmake.
add_library(lowlat_io STATIC src/ring.cpp)
add_library(lowlat::io ALIAS lowlat_io)
target_include_directories(lowlat_io PUBLIC include)
target_compile_features(lowlat_io PUBLIC cxx_std_23)
target_link_libraries(lowlat_io PUBLIC lowlat::uring Boost::asio)
target_link_libraries(lowlat_io PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(io-test tests/ring_test.cpp)
  target_link_libraries(io-test PRIVATE lowlat::io GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(io-test)
endif()
