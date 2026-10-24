# Ch11 C++ lane (11-stackful-stackless), wiring skeleton. Auto-discovered by examples/CMakeLists.txt.
# Boost 1.92.0 (fiber, context, asio) comes from cmake/deps.cmake. The measured variants arrive
# with the chapter; this target only proves the pinned libraries link and run.
add_library(lowlat_tasks STATIC src/tasks.cpp)
add_library(lowlat::tasks ALIAS lowlat_tasks)
target_include_directories(lowlat_tasks PUBLIC include)
target_compile_features(lowlat_tasks PUBLIC cxx_std_23)
target_link_libraries(lowlat_tasks PUBLIC Boost::fiber Boost::context Boost::asio)
target_link_libraries(lowlat_tasks PRIVATE lowlat::warnings)

if(BUILD_TESTING)
  add_executable(tasks-test tests/tasks_test.cpp)
  target_link_libraries(tasks-test PRIVATE lowlat::tasks GTest::gtest_main lowlat::warnings)
  include(GoogleTest)
  gtest_discover_tests(tasks-test)
endif()
