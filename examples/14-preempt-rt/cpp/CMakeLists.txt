# Ch14 C++ lane (14-preempt-rt). Auto-discovered by examples/CMakeLists.txt.
# The periodic waker for the cyclictest cross-check is common/cyclic-probe; this directory adds pi-demo, the
# priority-inversion demo (plain mutex against a priority-inheritance mutex).
add_library(lowlat_pi INTERFACE)
add_library(lowlat::pi ALIAS lowlat_pi)
target_include_directories(lowlat_pi INTERFACE include)
target_compile_features(lowlat_pi INTERFACE cxx_std_23)
target_link_libraries(lowlat_pi INTERFACE lowlat::cyclic)

add_executable(pi-demo src/pi_demo_main.cpp)
target_link_libraries(pi-demo PRIVATE lowlat::pi lowlat::warnings)

if(BUILD_TESTING)
  add_executable(pi-test tests/pi_mutex_test.cpp)
  target_link_libraries(pi-test PRIVATE lowlat::pi GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(pi-test)

  # The demo's shape without privilege: SCHED_OTHER threads, one CPU-free pass, both variants.
  foreach(_variant IN ITEMS plain-mutex pi-mutex)
    add_test(NAME pi-demo-${_variant}-no-rt COMMAND pi-demo --variant ${_variant} --no-rt --bursts 1 --burst-ms 2)
    set_tests_properties(pi-demo-${_variant}-no-rt PROPERTIES PASS_REGULAR_EXPRESSION "variant=${_variant}")
  endforeach()
endif()
