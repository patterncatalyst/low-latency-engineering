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

  # The demo's shape without privilege: SCHED_OTHER threads, three rounds, both variants.
  foreach(_variant IN ITEMS plain-mutex pi-mutex)
    add_test(NAME pi-demo-${_variant}-no-rt COMMAND pi-demo --variant ${_variant} --no-rt --rounds 3 --bursts 1 --burst-ms 2)
    set_tests_properties(pi-demo-${_variant}-no-rt PROPERTIES PASS_REGULAR_EXPRESSION "recorded=3")
  endforeach()

  # Usage errors: a misspelled option, RT without --cpu, and a run past the 30 s bound.
  add_test(NAME pi-demo-unknown-option COMMAND pi-demo --no-rt --prority 95)
  set_tests_properties(pi-demo-unknown-option PROPERTIES PASS_REGULAR_EXPRESSION "unknown option '--prority'")
  add_test(NAME pi-demo-rt-needs-cpu COMMAND pi-demo --variant pi-mutex)
  set_tests_properties(pi-demo-rt-needs-cpu PROPERTIES PASS_REGULAR_EXPRESSION "--cpu is required")
  add_test(NAME pi-demo-rt-rejects-cpu0 COMMAND pi-demo --variant pi-mutex --cpu 0)
  set_tests_properties(pi-demo-rt-rejects-cpu0 PROPERTIES PASS_REGULAR_EXPRESSION "housekeeping CPU")
  add_test(NAME pi-demo-total-bound COMMAND pi-demo --no-rt --rounds 2000 --bursts 5 --burst-ms 20)
  set_tests_properties(pi-demo-total-bound PROPERTIES PASS_REGULAR_EXPRESSION "the bound is")
endif()
