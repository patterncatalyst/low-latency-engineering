#!/usr/bin/env bash
# inputs-hash.sh LANE - print one sha256 over the repository files an image is built from.
#
#   examples/13-where-code-runs/containers/inputs-hash.sh cpp|java|python
#
# build-images.sh stamps it on the image as the label org.patterncatalyst.lowlat.inputs, and
# vm/run.sh recomputes it from the host tree and refuses a guest image whose label differs, so an
# image that is still the locked ID but was built from older sources can't run a lane. Paths are
# relative to the repository root and sorted, and build output, virtualenvs, caches and results are
# left out (as .dockerignore does), so the host tree and its deployed copy in the guest hash alike.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
case "${1:-}" in
  cpp) inputs=(versions.env scripts/deps contracts examples/CMakeLists.txt examples/CMakePresets.json examples/cmake
               examples/common examples/12-io-engines/cpp examples/13-where-code-runs/cpp
               examples/13-where-code-runs/containers/cpp/Containerfile) ;;
  java) inputs=(versions.env examples/pom.xml examples/common examples/12-io-engines/java examples/12-io-engines/quarkus
                examples/13-where-code-runs/java examples/13-where-code-runs/containers/java/Containerfile) ;;
  python) inputs=(examples/.python-version examples/13-where-code-runs/place-py
                  examples/13-where-code-runs/containers/python/Containerfile) ;;
  *) echo "usage: inputs-hash.sh cpp|java|python" >&2; exit 2 ;;
esac
cd "$ROOT"
for p in "${inputs[@]}"; do [[ -e $p ]] || { echo "inputs-hash.sh: $p is missing" >&2; exit 1; }; done
find "${inputs[@]}" \( -name build -o -name target -o -name '.venv*' -o -name results -o -name __pycache__ \
    -o -name .pytest_cache -o -name .ruff_cache -o -name .mypy_cache -o -name '.scratch' -o -name 'cmake-build-*' \) -prune \
    -o -type f ! -name '*.local.md' -print0 |
  LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
