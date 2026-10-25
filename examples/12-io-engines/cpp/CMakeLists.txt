# Ch12 C++ lane (12-io-engines). Auto-discovered by examples/CMakeLists.txt.
# liburing 2.15 (lowlat::uring) and Boost.Asio 1.92.0 come from cmake/deps.cmake. The hand-off pool
# reuses Ch10's multi-producer log, so this lane depends on lowlat::lockfree (examples/10-lockfree-waitfree).
add_library(lowlat_io STATIC src/ring.cpp src/sockets.cpp)
add_library(lowlat::io ALIAS lowlat_io)
target_include_directories(lowlat_io PUBLIC include)
target_compile_features(lowlat_io PUBLIC cxx_std_23)
target_link_libraries(lowlat_io PUBLIC lowlat::uring lowlat::lockfree lowlat::line_consumer lowlat::flat_parcel_v1)
target_link_libraries(lowlat_io PRIVATE lowlat::warnings)

add_executable(io-receive src/receive_main.cpp)
target_link_libraries(io-receive PRIVATE lowlat::io lowlat::warnings)

# The Asio io_uring backend is a build-time switch: BOOST_ASIO_HAS_IO_URING turns it on for files and
# BOOST_ASIO_DISABLE_EPOLL moves sockets onto it too (the pins notes, "Boost.Asio io_uring"). The two
# definitions are PRIVATE to this one target, so no other target is compiled with them.
add_executable(io-receive-asio src/asio_main.cpp)
target_compile_definitions(io-receive-asio PRIVATE BOOST_ASIO_HAS_IO_URING BOOST_ASIO_DISABLE_EPOLL)
target_link_libraries(io-receive-asio PRIVATE lowlat::io Boost::asio lowlat::warnings)

if(BUILD_TESTING)
  add_executable(io-test tests/ring_test.cpp tests/engines_test.cpp)
  target_link_libraries(io-test PRIVATE lowlat::io GTest::gtest_main lowlat::warnings)
  target_compile_definitions(io-test PRIVATE
    LOWLAT_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../common/measure-fixtures")
  include(GoogleTest)
  gtest_discover_tests(io-test)
endif()
