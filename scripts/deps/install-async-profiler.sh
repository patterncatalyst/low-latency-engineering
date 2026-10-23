#!/usr/bin/env bash
# install-async-profiler.sh - download the pinned async-profiler (Apache-2.0, linux x64) from
# versions.env, verify its sha256 and unpack it under ~/.cache/lowlat. Never touches the
# system: no sudo, no packages. Idempotent: exits 0 at once when the pin is already unpacked.
#
#   scripts/deps/install-async-profiler.sh
#
# Result: ~/.cache/lowlat/async-profiler-$ASYNC_PROFILER_VERSION-linux-x64/ (lib/libasyncProfiler.so,
# bin/asprof). examples/05-jvm-costs/verify.sh picks it up from there; ASYNC_PROFILER_LIB overrides.
# The archive stays in ~/.cache/lowlat/downloads, checked against the pinned digest on every run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../versions.env
. "$ROOT/versions.env"

CACHE="$HOME/.cache/lowlat"
DL="$CACHE/downloads"
DEST="$CACHE/async-profiler-$ASYNC_PROFILER_VERSION-linux-x64"
ARCHIVE="$DL/async-profiler-$ASYNC_PROFILER_VERSION-linux-x64.tar.gz"

if [ -f "$DEST/lib/libasyncProfiler.so" ]; then
  echo "async-profiler $ASYNC_PROFILER_VERSION already installed in $DEST"
  exit 0
fi

mkdir -p "$DL"
[ -f "$ARCHIVE" ] && [ "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)" = "$ASYNC_PROFILER_SHA256" ] || {
  curl -fsSL -o "$ARCHIVE.part" "$ASYNC_PROFILER_URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
}
[ "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)" = "$ASYNC_PROFILER_SHA256" ] || {
  echo "sha256 mismatch for $ARCHIVE" >&2
  rm -f "$ARCHIVE"
  exit 1
}

# Unpack beside the destination and rename, so an interrupted run never leaves a half-filled dir.
rm -rf "${DEST:?}.part"
mkdir -p "$DEST.part"
tar -C "$DEST.part" --strip-components=1 -xzf "$ARCHIVE"
[ -f "$DEST.part/lib/libasyncProfiler.so" ] || { echo "archive has no lib/libasyncProfiler.so" >&2; rm -rf "$DEST.part"; exit 1; }
rm -rf "${DEST:?}"
mv "$DEST.part" "$DEST"
echo "installed async-profiler $ASYNC_PROFILER_VERSION into $DEST"
