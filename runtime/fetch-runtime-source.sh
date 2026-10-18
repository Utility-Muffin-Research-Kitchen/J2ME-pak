#!/usr/bin/env bash
# Fetch the GPL corresponding source of the shipped Java runtime into
# build/downloads, check it against runtime/runtime.lock.json, and print its
# path. The build never needs it; `make dist-source` publishes it beside the
# pak.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/runtime/runtime.lock.json"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
DOWNLOADS="$BUILD_DIR/downloads"

die() { echo "fetch-runtime-source: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

read -r URL FILE EXPECTED < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["runtime_source"]
print(d["url"], d["file"], d["sha256"])
' "$LOCK")

mkdir -p "$DOWNLOADS"
if [ ! -f "$DOWNLOADS/$FILE" ]; then
  echo "fetch-runtime-source: downloading $URL" >&2
  curl -fsSL --retry 3 -o "$DOWNLOADS/$FILE.part" "$URL"
  mv "$DOWNLOADS/$FILE.part" "$DOWNLOADS/$FILE"
fi

ACTUAL="$(python3 -c 'import hashlib,sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for block in iter(lambda: f.read(1 << 20), b""):
        h.update(block)
print(h.hexdigest())' "$DOWNLOADS/$FILE")"
[ "$ACTUAL" = "$EXPECTED" ] || die "$FILE sha256 mismatch
  got:    $ACTUAL
  locked: $EXPECTED"

echo "$DOWNLOADS/$FILE"
