cmake_minimum_required(VERSION 4.3)
project(lowlat_examples VERSION 1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(CTest)
include(cmake/deps.cmake)

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
