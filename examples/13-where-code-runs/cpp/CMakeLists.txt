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

# The four binaries every lane runs link libstdc++ and libgcc statically, so the same file starts on the host
# (Fedora), in the guest and in a ubi-minimal container without depending on whichever libstdc++ is installed there.
# glibc stays dynamic and still differs between those places; each lane records its glibc version.
# line-simulator and io-receive belong to other directories; target_link_options applies to a target from anywhere.
# libstdc++ is GPLv3 with the GCC Runtime Library Exception, which permits linking it into a program under any licence.
#
# LOWLAT_STATIC_LIBSTDCXX=ON (the container build sets it) requires the static libraries and fails to link without them.
# AUTO (the default) uses them when this toolchain has them, so a developer machine without libstdc++-static still builds
# these targets dynamically. OFF never links statically.
set(LOWLAT_STATIC_LIBSTDCXX "AUTO" CACHE STRING "Link the Ch13 lane binaries with -static-libstdc++ -static-libgcc: AUTO, ON or OFF")
set_property(CACHE LOWLAT_STATIC_LIBSTDCXX PROPERTY STRINGS AUTO ON OFF)
set(_static_libstdcxx FALSE)
if(LOWLAT_STATIC_LIBSTDCXX STREQUAL "ON")
  set(_static_libstdcxx TRUE)
elseif(LOWLAT_STATIC_LIBSTDCXX STREQUAL "AUTO")
  include(CheckCXXSourceCompiles)
  set(CMAKE_REQUIRED_LINK_OPTIONS -static-libstdc++ -static-libgcc)
  check_cxx_source_compiles("#include <string>\nint main() { std::string s{\"x\"}; return static_cast<int>(s.size()) - 1; }" LOWLAT_HAVE_STATIC_LIBSTDCXX)
  unset(CMAKE_REQUIRED_LINK_OPTIONS)
  set(_static_libstdcxx ${LOWLAT_HAVE_STATIC_LIBSTDCXX})
endif()
if(_static_libstdcxx)
  foreach(_lane_binary IN ITEMS place-probe busy-pool line-simulator io-receive)
    if(TARGET ${_lane_binary})
      target_link_options(${_lane_binary} PRIVATE -static-libstdc++ -static-libgcc)
    endif()
  endforeach()
else()
  message(STATUS "Ch13 lane binaries: libstdc++ is linked dynamically (LOWLAT_STATIC_LIBSTDCXX=${LOWLAT_STATIC_LIBSTDCXX})")
endif()
