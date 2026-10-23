cmake_minimum_required(VERSION 4.3)
project(lowlat_examples VERSION 1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(CTest)
include(cmake/deps.cmake)

# Warning flags, linked PRIVATE by every first-party target (not by lowlat_proto,
# which compiles generated code).
add_library(lowlat_warnings INTERFACE)
add_library(lowlat::warnings ALIAS lowlat_warnings)
target_compile_options(lowlat_warnings INTERFACE -Wall -Wextra -Wpedantic)
# GCC warns that std::hardware_destructive_interference_size is not ABI-stable across compiler
# flags (-Winterference-size). The padded types are header-only and no layout crosses a build, so
# the warning carries no information here.
target_compile_options(lowlat_warnings INTERFACE $<$<CXX_COMPILER_ID:GNU>:-Wno-interference-size>)

# -DLOWLAT_SANITIZE=address,undefined (the "sanitize" preset) instruments the
# first-party targets through the same interface. The generated protobuf code
# (lowlat_proto) stays uninstrumented: protobuf's headers switch on
# extra has-bit checks under ASan that the pinned, unsanitized libprotobuf does
# not match.
set(LOWLAT_SANITIZE "" CACHE STRING "Comma-separated -fsanitize= list for first-party targets")
if(LOWLAT_SANITIZE)
  target_compile_options(lowlat_warnings INTERFACE
    -fsanitize=${LOWLAT_SANITIZE} -fno-sanitize-recover=undefined -fno-omit-frame-pointer)
  target_link_options(lowlat_warnings INTERFACE -fsanitize=${LOWLAT_SANITIZE})
endif()

# Pinned protobuf from the lowlat prefix (scripts/deps/build-protobuf.sh),
# never the distro package.
find_package(Protobuf CONFIG REQUIRED)

# Wire contract shared by all three languages: contracts/proto.
set(LOWLAT_PROTO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../contracts/proto")
add_library(lowlat_proto STATIC)
protobuf_generate(
  TARGET lowlat_proto
  LANGUAGE cpp
  IMPORT_DIRS "${LOWLAT_PROTO_ROOT}"
  PROTOS
    "${LOWLAT_PROTO_ROOT}/lowlat/line/v1/parcel.proto"
    "${LOWLAT_PROTO_ROOT}/lowlat/line/v1/divert.proto")
target_include_directories(lowlat_proto PUBLIC "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(lowlat_proto PUBLIC protobuf::libprotobuf)
add_library(lowlat::proto ALIAS lowlat_proto)

# Flat wire layout (contracts/flat/parcel-v1): a header-only contract, plus its golden files.
set(LOWLAT_FLAT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../contracts/flat")
cmake_path(NORMAL_PATH LOWLAT_FLAT_ROOT)
add_library(lowlat_flat_parcel_v1 INTERFACE)
add_library(lowlat::flat_parcel_v1 ALIAS lowlat_flat_parcel_v1)
target_include_directories(lowlat_flat_parcel_v1 INTERFACE "${LOWLAT_FLAT_ROOT}")
target_compile_features(lowlat_flat_parcel_v1 INTERFACE cxx_std_23)

add_subdirectory(common/proto-smoke)
add_subdirectory(common/measure-cpp)
add_subdirectory(common/line-simulator)

# Chapter examples: every NN-<topic>/cpp directory with a CMakeLists.txt is
# picked up at configure time (re-run the configure step after adding one).
file(GLOB _lowlat_example_dirs LIST_DIRECTORIES true RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}"
     "${CMAKE_CURRENT_SOURCE_DIR}/[0-9][0-9]-*/cpp")
list(SORT _lowlat_example_dirs)
foreach(_dir IN LISTS _lowlat_example_dirs)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_dir}/CMakeLists.txt")
    add_subdirectory("${_dir}")
  endif()
endforeach()
