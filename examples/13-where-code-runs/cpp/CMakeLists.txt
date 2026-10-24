# Ch13 C++ lane (13-where-code-runs). Auto-discovered by examples/CMakeLists.txt.
#
# lowlat_place: the cgroup probe (cpu.max, cpuset.cpus.effective, cpu.stat), the io_uring_setup errno probe and
# the external-linkage sink. Three executables run in every lane:
#   place-probe   what this process sees of its CPUs, and io_uring_setup's errno
#   busy-pool     four busy decide workers for the quota-against-cpuset lane
# and the lanes also run the Ch12 receive consumer (io-receive) and the line simulator, so one binary of
# each serves the host, the guest and the container.
add_library(lowlat_place STATIC src/cgroup_probe.cpp src/sink.cpp)
add_library(lowlat::place ALIAS lowlat_place)
target_include_directories(lowlat_place PUBLIC include)
target_compile_features(lowlat_place PUBLIC cxx_std_23)
target_link_libraries(lowlat_place PUBLIC lowlat::lockfree)
target_link_libraries(lowlat_place PRIVATE lowlat::warnings)

add_executable(place-probe src/place_probe_main.cpp)
target_link_libraries(place-probe PRIVATE lowlat::place lowlat::warnings)

add_executable(busy-pool src/busy_pool_main.cpp)
target_link_libraries(busy-pool PRIVATE lowlat::place lowlat::warnings)

if(BUILD_TESTING)
  add_executable(place-test tests/cgroup_probe_test.cpp)
  target_link_libraries(place-test PRIVATE lowlat::place GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(place-test)
endif()
