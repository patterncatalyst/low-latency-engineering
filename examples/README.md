# Examples

Original C++23, Python 3.14 and Java 25 examples. Each language is built with its
own idiomatic tool: CMake presets, Maven, a uv workspace. All three share one wire
contract, `contracts/proto`, compiled by one pinned protoc.

## Layout

```
versions.env                 (repo root) pinned versions read by scripts
scripts/deps/build-protobuf.sh   builds protobuf + abseil into ~/.cache/lowlat/prefix
scripts/gen-python-proto.sh      regenerates the Python protobuf modules
examples/
  CMakeLists.txt, CMakePresets.json, cmake/deps.cmake    C++ superproject
  pom.xml                                                Java aggregator
  pyproject.toml                                         uv workspace root
  common/
    proto-smoke/   C++ smoke executable + GoogleTest round trip (CTest)
    proto-java/    Java module, generated from contracts/proto by protobuf-maven-plugin
    proto-py/      Python package lowlat_proto (src layout)
  NN-<topic>/      one directory per chapter example, each with verify.sh
```

Python workspace convention: every package is a `*-py` directory
(`common/*-py` today); adding one needs no change to the root file.

## Build

First, once per machine (builds the pinned protoc into `~/.cache/lowlat/prefix`;
never touches system packages):

```
scripts/deps/build-protobuf.sh
```

C++ (from `examples/`):

```
cmake --preset release && cmake --build --preset release && ctest --preset release
```

Java (from the repo root):

```
mvn -B -f examples/pom.xml verify
```

Python (from `examples/`):

```
../scripts/gen-python-proto.sh && uv sync --all-packages && uv run pytest && uv run ruff check
```

## Where versions live

`versions.env` (repo root) is the machine-readable source for protobuf and abseil;
`scripts/deps/build-protobuf.sh` and `scripts/check-prereqs.sh` read it. The same
numbers are repeated in each tool's own syntax and must move together:
`examples/cmake/deps.cmake` (FetchContent URL + SHA256), `examples/pom.xml`
(properties), `examples/pyproject.toml` and `common/proto-py/pyproject.toml`.
`_plans/dependency-pins.md` is the human-readable record (licence, source, survey date).

## Design choices

- **Release preset:** Release with `-O2 -g -fno-omit-frame-pointer`. Frame pointers
  and symbols make `perf` call graphs usable at negligible cost. Clang is the
  compiler (the same one that builds the protobuf prefix, so one ABI and one
  standard library); GCC 16 also works with `-DCMAKE_CXX_COMPILER=g++` for a
  prefix built with it.
- **Static protobuf prefix:** no runtime rpath or `LD_LIBRARY_PATH` to manage.
- **Python generated code is built, not committed:** the pb2 files are tied to the
  exact protoc, so committing them invites a stale copy. `gen-python-proto.sh` writes
  them to the git-ignored `common/proto-py/src/lowlat/`, and `conftest.py` stops with
  an instruction if they are missing.
- **Java protoc:** the Maven Central `com.google.protobuf:protoc` artifact at the
  pinned version, resolved by the plugin, so Java never uses a system protoc either.

## Measurement runs

Numbers are produced only by each example's `verify.sh`, which records the machine
profile with the result. Building and running the unit tests above is a smoke
check, not a measurement.
