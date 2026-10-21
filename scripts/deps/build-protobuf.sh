#!/usr/bin/env bash
# build-protobuf.sh - build the pinned protobuf (C++ library + protoc) and the
# abseil-cpp it requires from source into $LOWLAT_PREFIX. Never touches the
# system. Idempotent: exits 0 at once when the prefix already has the pin.
#
#   scripts/deps/build-protobuf.sh            # build if needed
#   LOWLAT_PREFIX=/some/dir scripts/deps/build-protobuf.sh
#
# Design:
#  - Release tarballs with sha256 verification (reproducible, no submodules).
#  - STATIC libraries, built -fPIC. A static prefix has no runtime rpath or
#    LD_LIBRARY_PATH to manage, and the examples' binaries stay relocatable.
#    protoc itself is self-contained.
#  - C++23: protobuf needs C++17 and abseil 20250512.1 builds in 23, so the
#    book-wide standard is used. ABSL_PROPAGATE_CXX_STD makes abseil's exported
#    targets carry the standard (abseil's std::string_view etc. selection must
#    match the consumers', which is why consumers must also use C++23).
#  - Compiler: clang if present (the release preset uses clang), else the
#    default. Override with CC/CXX.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../versions.env
. "$ROOT/versions.env"

PREFIX="${LOWLAT_PREFIX:-$HOME/.cache/lowlat/prefix}"
WORK="${LOWLAT_BUILD_DIR:-$HOME/.cache/lowlat/build}"
DL="$HOME/.cache/lowlat/downloads"

if [ -x "$PREFIX/bin/protoc" ] && [ "$("$PREFIX/bin/protoc" --version 2>/dev/null)" = "libprotoc $PROTOBUF_VERSION" ]; then
  echo "protoc $PROTOBUF_VERSION already installed in $PREFIX"
  exit 0
fi

if [ -z "${CXX:-}" ] && command -v clang++ >/dev/null; then
  export CC=clang CXX=clang++
fi
command -v cmake >/dev/null && command -v ninja >/dev/null || { echo "cmake and ninja are required" >&2; exit 1; }

mkdir -p "$PREFIX" "$WORK" "$DL"

fetch() { # name url sha256
  local f="$DL/$1.tar.gz"
  [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$3" ] || {
    curl -fsSL -o "$f.part" "$2"
    mv "$f.part" "$f"
  }
  [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$3" ] || { echo "sha256 mismatch for $1" >&2; exit 1; }
}
unpack() { # name -> dir
  rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"
  tar -C "$WORK/$1" --strip-components=1 -xzf "$DL/$1.tar.gz"
}

common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=23 -DCMAKE_CXX_STANDARD_REQUIRED=ON
        -DCMAKE_CXX_EXTENSIONS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX")

fetch abseil "$ABSL_URL" "$ABSL_SHA256"
unpack abseil
cmake -S "$WORK/abseil" -B "$WORK/abseil/build" "${common[@]}" \
  -DABSL_PROPAGATE_CXX_STD=ON -DABSL_BUILD_TESTING=OFF -DABSL_ENABLE_INSTALL=ON
cmake --build "$WORK/abseil/build" -j"$(nproc)"
cmake --install "$WORK/abseil/build"

fetch protobuf "$PROTOBUF_URL" "$PROTOBUF_SHA256"
unpack protobuf
cmake -S "$WORK/protobuf" -B "$WORK/protobuf/build" "${common[@]}" \
  -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=OFF \
  -Dprotobuf_ABSL_PROVIDER=package -Dprotobuf_LOCAL_DEPENDENCIES_ONLY=ON \
  -Dprotobuf_INSTALL=ON -Dprotobuf_WITH_ZLIB=OFF
cmake --build "$WORK/protobuf/build" -j"$(nproc)"
cmake --install "$WORK/protobuf/build"

got="$("$PREFIX/bin/protoc" --version)"
[ "$got" = "libprotoc $PROTOBUF_VERSION" ] || { echo "installed $got, expected $PROTOBUF_VERSION" >&2; exit 1; }
rm -rf "$WORK/abseil" "$WORK/protobuf"
echo "installed $got into $PREFIX"
