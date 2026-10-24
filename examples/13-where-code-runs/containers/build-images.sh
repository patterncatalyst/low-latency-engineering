#!/usr/bin/env bash
# build-images.sh - build the three Ch13 images and write their image IDs into IMAGES.lock.
#
#   examples/13-where-code-runs/containers/build-images.sh [cpp|java|python ...]
#
# Run it IN THE LAB GUEST from the deployed repository root (scripts/lab/deploy-to-vm.sh puts it
# there); it uses the guest's Docker Engine and needs network for the build. It never runs on the
# host. Each image is built with the repository root as context (see README.md), then
# `docker image inspect --format '{{.Id}}'` is written into the image's line of IMAGES.lock.
# Before building, the FROM lines of each Containerfile are compared with the base refs in the lock.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LOCK="$HERE/IMAGES.lock"

declare -A REF=([cpp]=lowlat/place-cpp:r04 [java]=lowlat/place-java:r04 [python]=lowlat/place-py:r04)
lanes=("$@")
((${#lanes[@]})) || lanes=(cpp java python)

command -v docker >/dev/null || { echo "docker not found (run this in the lab guest)" >&2; exit 1; }

for lane in "${lanes[@]}"; do
  ref="${REF[$lane]:-}"
  [[ -n "$ref" ]] || { echo "unknown lane '$lane' (cpp, java, python)" >&2; exit 2; }
  cf="$HERE/$lane/Containerfile"
  line="$(awk -v r="$ref" '!/^[[:space:]]*(#|$)/ && index($1, r "@") == 1 { print; exit }' "$LOCK")"
  [[ -n "$line" ]] || { echo "$ref is not listed in $LOCK" >&2; exit 1; }
  for base in $(awk '{ for (i = 2; i <= NF; i++) { f = $i; sub(/^builder=/, "", f); print f } }' <<<"$line"); do
    grep -q "^FROM $base" "$cf" || { echo "$cf has no FROM $base (IMAGES.lock and the Containerfile disagree)" >&2; exit 1; }
  done
  echo "== building $ref"
  docker build -f "$cf" -t "$ref" "$ROOT"
  id="$(docker image inspect --format '{{.Id}}' "$ref")"
  [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "unexpected image id '$id'" >&2; exit 1; }
  awk -v r="$ref" -v id="$id" '
    !/^[[:space:]]*(#|$)/ && index($1, r "@") == 1 { $1 = r "@" id }
    { print }' "$LOCK" >"$LOCK.tmp"
  mv "$LOCK.tmp" "$LOCK"
  echo "locked $ref@$id"
done
