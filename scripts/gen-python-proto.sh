#!/usr/bin/env bash
# gen-python-proto.sh - regenerate the Python protobuf modules from
# contracts/proto with the PINNED protoc in the lowlat prefix (never the
# distro protoc). Output goes to examples/common/proto-py/src/lowlat/ and is
# git-ignored: generated at build, not committed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
. "$ROOT/versions.env"
PREFIX="${LOWLAT_PREFIX:-$HOME/.cache/lowlat/prefix}"
PROTOC="$PREFIX/bin/protoc"
if [[ ! -x $PROTOC || "$("$PROTOC" --version)" != "libprotoc $PROTOBUF_VERSION" ]]; then
  echo "pinned protoc $PROTOBUF_VERSION missing: run scripts/deps/build-protobuf.sh" >&2
  exit 1
fi
OUT="$ROOT/examples/common/proto-py/src"
rm -rf "$OUT/lowlat"
mkdir -p "$OUT"
"$PROTOC" -I "$ROOT/contracts/proto" --python_out="$OUT" --pyi_out="$OUT" \
  "$ROOT"/contracts/proto/lowlat/line/v1/*.proto
echo "generated with $("$PROTOC" --version) into $OUT/lowlat"
