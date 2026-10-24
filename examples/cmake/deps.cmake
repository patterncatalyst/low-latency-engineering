# Pinned third-party sources. Each is a release tarball with a SHA256, so a
# changed upstream tag cannot slip in. Versions mirror /versions.env and
# _plans/dependency-pins.md. Hashes computed from the downloaded assets on
# 2026-10-21.
include(FetchContent)

# HdrHistogram_c 0.12.1: static library only, no tests/examples/shared.
set(HDR_HISTOGRAM_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(HDR_HISTOGRAM_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(HDR_HISTOGRAM_BUILD_STATIC ON CACHE BOOL "" FORCE)
set(HDR_HISTOGRAM_INSTALL_SHARED OFF CACHE BOOL "" FORCE)
FetchContent_Declare(hdr_histogram
  URL https://github.com/HdrHistogram/HdrHistogram_c/archive/refs/tags/0.12.1.tar.gz
  URL_HASH SHA256=b2cff564b49f900e7f951c95428100a4aed36561703237ffc5e41b4843d804ce
  SYSTEM
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)

# Google Benchmark v1.10.0
set(BENCHMARK_ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(BENCHMARK_ENABLE_GTEST_TESTS OFF CACHE BOOL "" FORCE)
set(BENCHMARK_INSTALL_DOCS OFF CACHE BOOL "" FORCE)
FetchContent_Declare(benchmark
  URL https://github.com/google/benchmark/archive/refs/tags/v1.10.0.tar.gz
  URL_HASH SHA256=acc5c7c0fbed855c4aaa2d7c3c36fb82b0c15c28f4e151e3f679c2fc0aa404af
  SYSTEM
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)

# GoogleTest v1.18.0
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
FetchContent_Declare(googletest
  URL https://github.com/google/googletest/releases/download/v1.18.0/googletest-1.18.0.tar.gz
  URL_HASH SHA256=6e3191c1455468b3fc35a417fb565c1c5071aee1b7e7f85e30cf48a98d37d8b5
  SYSTEM
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)

# nlohmann/json v3.12.0 (upstream's json.tar.xz: headers and CMake only)
set(JSON_Install OFF CACHE BOOL "" FORCE)
FetchContent_Declare(nlohmann_json
  URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
  URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
  SYSTEM
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)

FetchContent_MakeAvailable(hdr_histogram benchmark nlohmann_json)
if(BUILD_TESTING)
  FetchContent_MakeAvailable(googletest)
endif()

# ---- r04 (Part 4, chapters 11 to 13): Boost and liburing, pinned upstream sources -------------
# Distro boost-devel and liburing-devel are never the source (_plans/dependency-pins.md "r04 pins").
# Nothing here runs unless LOWLAT_BUILD_R04 is ON (the default), so a configure with
# -DLOWLAT_BUILD_R04=OFF skips the 108 MB Boost download and the liburing fetch entirely.
option(LOWLAT_BUILD_R04 "Build chapters 11 to 13 (needs Boost 1.92.0 and liburing 2.15 sources)" ON)

if(LOWLAT_BUILD_R04)
  # Boost 1.92.0, upstream's CMake superproject tarball. Only asio (header-only), fiber and context
  # (compiled, static) are configured, plus the libraries they depend on. The release was
  # downloaded and hashed on 2026-10-23; the hash equals the one in the release's .txt asset.
  FetchContent_Declare(Boost
    URL https://github.com/boostorg/boost/releases/download/boost-1.92.0/boost-1.92.0-cmake.tar.xz
    URL_HASH SHA256=9bed76128d4e46755dbe818487788c6fceb6f72b378f4daa49b7e1e600d9088d
    SYSTEM
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  set(BOOST_INCLUDE_LIBRARIES "asio;fiber;context")
  set(BOOST_ENABLE_MPI OFF)
  set(BOOST_ENABLE_PYTHON OFF)
  # Static libraries and no Boost tests, scoped to this call so the other dependencies keep
  # their own settings.
  set(_lowlat_saved_shared "${BUILD_SHARED_LIBS}")
  set(BUILD_SHARED_LIBS OFF)
  set(_lowlat_saved_testing "${BUILD_TESTING}")
  set(BUILD_TESTING OFF)
  FetchContent_MakeAvailable(Boost)
  set(BUILD_SHARED_LIBS "${_lowlat_saved_shared}")
  set(BUILD_TESTING "${_lowlat_saved_testing}")

  # liburing 2.15: its own configure script and Makefile, built in the build tree. Only
  # src/liburing.a is made and nothing is installed anywhere (the include directory is the
  # source tree's src/include, whose generated headers configure writes in place). GitHub does
  # not guarantee a tag archive's bytes, so URL_HASH is the fetch-time check.
  include(ExternalProject)
  set(_lowlat_uring_src "${CMAKE_BINARY_DIR}/_deps/liburing-src")
  ExternalProject_Add(liburing_ep
    URL https://github.com/axboe/liburing/archive/refs/tags/liburing-2.15.tar.gz
    URL_HASH SHA256=8d052f2622dcb3678cbaee5ff582a87572672a6c0a56533cdda5b65cb636120a
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    PREFIX "${CMAKE_BINARY_DIR}/_deps/liburing-ep"
    SOURCE_DIR "${_lowlat_uring_src}"
    BUILD_IN_SOURCE TRUE
    CONFIGURE_COMMAND ./configure "--prefix=${CMAKE_BINARY_DIR}/_deps/liburing-ep"
                      "--cc=${CMAKE_C_COMPILER}" "--cxx=${CMAKE_CXX_COMPILER}"
    BUILD_COMMAND make -C src liburing.a
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS "${_lowlat_uring_src}/src/liburing.a")
  file(MAKE_DIRECTORY "${_lowlat_uring_src}/src/include")
  add_library(lowlat::uring STATIC IMPORTED GLOBAL)
  set_target_properties(lowlat::uring PROPERTIES
    IMPORTED_LOCATION "${_lowlat_uring_src}/src/liburing.a"
    INTERFACE_INCLUDE_DIRECTORIES "${_lowlat_uring_src}/src/include")
  add_dependencies(lowlat::uring liburing_ep)
endif()
