# Ch16 C++ lane (16-cyclictest). Auto-discovered by examples/CMakeLists.txt.
# The probe itself is common/cyclic-probe (lowlat::cyclic); this directory fixes the parameters that match the
# chapter's cyclictest `method` lane, so the probe and the tool measure the same thing.
add_library(lowlat_method INTERFACE)
add_library(lowlat::method ALIAS lowlat_method)
target_include_directories(lowlat_method INTERFACE include)
target_compile_features(lowlat_method INTERFACE cxx_std_23)
target_link_libraries(lowlat_method INTERFACE lowlat::cyclic)

if(BUILD_TESTING)
  add_executable(method-test tests/method_test.cpp)
  target_link_libraries(method-test PRIVATE lowlat::method GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(method-test)
endif()
