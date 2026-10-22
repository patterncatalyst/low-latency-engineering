# Ch2 C++: Little's Law on the line and Amdahl's Law with a serial lock.
add_library(lowlat_ch02_model INTERFACE)
add_library(lowlat::ch02_model ALIAS lowlat_ch02_model)
target_include_directories(lowlat_ch02_model INTERFACE include)
target_compile_features(lowlat_ch02_model INTERFACE cxx_std_23)

add_executable(littles-consumer src/littles.cpp)
target_link_libraries(littles-consumer PRIVATE lowlat::ch02_model lowlat::line_consumer lowlat::warnings)

find_package(Threads REQUIRED)
add_executable(amdahl-cpp src/amdahl.cpp)
target_link_libraries(amdahl-cpp PRIVATE lowlat::ch02_model lowlat::line lowlat::measure Threads::Threads lowlat::warnings)

if(BUILD_TESTING)
  add_executable(ch02-model-test tests/model_test.cpp)
  target_link_libraries(ch02-model-test PRIVATE lowlat::ch02_model GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(ch02-model-test)
endif()
