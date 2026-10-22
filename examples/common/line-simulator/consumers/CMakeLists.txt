# One consumer per language lives beside this file (see README.md). Only the
# C++ one is built by this CMake superproject; the Python consumer is built by
# uv (examples/pyproject.toml) and the Java one by Maven (examples/pom.xml).
add_subdirectory(cpp)
