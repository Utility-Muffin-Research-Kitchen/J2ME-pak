#!/usr/bin/env bash
# Make build/freej2me-src a checkout of the commit pinned in core/core.lock.json.
#
# Both binaries this repository ships come from that one commit: the libretro
# core (C) and the jar it starts (Java). They talk over an unversioned pipe
# protocol, so they must never be built from different revisions.
#
#   scripts/fetch-source.sh          clone or fetch, then print the checkout path
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/core/core.lock.json"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
SRC_DIR="$BUILD_DIR/freej2me-src"

die() { echo "fetch-source: $*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

read -r SOURCE_URL SOURCE_COMMIT < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["source"]
print(d["url"], d["commit"])
' "$LOCK")

mkdir -p "$BUILD_DIR"
if [ ! -d "$SRC_DIR/.git" ]; then
  echo "fetch-source: cloning $SOURCE_URL" >&2
  git init -q "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$SOURCE_URL"
fi

if [ "$(git -C "$SRC_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$SOURCE_COMMIT" ]; then
  echo "fetch-source: fetching pinned commit $SOURCE_COMMIT" >&2
  git -C "$SRC_DIR" fetch -q --depth 1 origin "$SOURCE_COMMIT"
  git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD
fi

ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
[ "$ACTUAL_COMMIT" = "$SOURCE_COMMIT" ] \
  || die "checked out $ACTUAL_COMMIT, lock says $SOURCE_COMMIT"

echo "$SRC_DIR"
