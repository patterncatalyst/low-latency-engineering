add_executable(proto-smoke main.cpp)
target_link_libraries(proto-smoke PRIVATE lowlat::proto)

add_executable(proto-smoke-test test.cpp)
target_link_libraries(proto-smoke-test PRIVATE lowlat::proto GTest::gtest_main)
include(GoogleTest)
gtest_discover_tests(proto-smoke-test)

add_test(NAME proto-smoke COMMAND proto-smoke)
set_tests_properties(proto-smoke PROPERTIES PASS_REGULAR_EXPRESSION "serialized [0-9]+ bytes")
