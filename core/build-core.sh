#!/usr/bin/env bash
# Build the FreeJ2ME-Plus libretro core for the Miniloong Pocket 1.
#
# Self-contained on purpose. A clean clone of THIS repository plus Docker is
# the entire toolchain: no sibling checkouts, no UMRK workspace layout, no
# locally built images. Everything it needs is pinned in core/core.lock.json.
#
#   ./core/build-core.sh              build into build/, verify against the lock
#   FORCE=1 ./core/build-core.sh      rebuild even if the artifact is present
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/core/core.lock.json"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
OUT_DIR="$BUILD_DIR/core"

die() { echo "build-core: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

lock_get() {
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    d = d[key]
print(d)' "$LOCK" "$1"
}

sha256() {
  python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

SOURCE_COMMIT="$(lock_get source.commit)"
CORE_DIR_REL="$(lock_get core.source_dir)"
IMAGE="$(lock_get toolchain.image)"
DIGEST="$(lock_get toolchain.digest)"
CROSS="$(lock_get toolchain.cross_prefix)"
ARTIFACT="$(lock_get artifact.file_name)"
INFO_ARTIFACT="$(lock_get artifact.info_file_name)"
EXPECTED_SHA="$(lock_get artifact.sha256)"
EXPECTED_INFO_SHA="$(lock_get artifact.info_sha256)"
PATCH_FILE="$REPO_ROOT/$(lock_get patch.file)"
EXPECTED_PATCH_SHA="$(lock_get patch.sha256)"

# A tag can move; a digest cannot.
IMAGE_REF="${IMAGE%%:*}@${DIGEST}"

[ "$(sha256 "$PATCH_FILE")" = "$EXPECTED_PATCH_SHA" ] \
  || die "patch sha256 mismatch: $(sha256 "$PATCH_FILE")"

mkdir -p "$OUT_DIR"

# What the cached core was built from. A changed patch or commit is a rebuild,
# not a reuse.
STAMP="$OUT_DIR/.built-from"
WANT_STAMP="$SOURCE_COMMIT $EXPECTED_PATCH_SHA"

if [ -f "$OUT_DIR/$ARTIFACT" ] && [ -f "$OUT_DIR/$INFO_ARTIFACT" ] && \
   [ "$(cat "$STAMP" 2>/dev/null || true)" = "$WANT_STAMP" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "build-core: core already present (FORCE=1 to rebuild)"
else
  SRC_DIR="$("$REPO_ROOT/scripts/fetch-source.sh")"

  if git -C "$SRC_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    echo "build-core: Leaf patch already applied"
  else
    # The checkout is this script's cache. Anything in it that is not this
    # exact patch (an older revision of it, say) is discarded first.
    git -C "$SRC_DIR" checkout -q -- .
    git -C "$SRC_DIR" apply --check "$PATCH_FILE" \
      || die "Leaf patch does not apply to pinned source"
    git -C "$SRC_DIR" apply "$PATCH_FILE"
  fi

  if [ "${FORCE:-0}" = "1" ]; then
    # Stale objects compiled with another command line would make a rebuild
    # verify something it did not build.
    echo "build-core: removing cached build products for a clean rebuild"
    git -C "$SRC_DIR" clean -qfdx
  fi

  rm -f "$OUT_DIR/$ARTIFACT" "$OUT_DIR/$INFO_ARTIFACT" "$STAMP"

  echo "build-core: building in $IMAGE_REF"
  docker run --rm \
    -v "$SRC_DIR":/src \
    -v "$OUT_DIR":/out \
    -w "/src/$CORE_DIR_REL" \
    "$IMAGE_REF" \
    /bin/sh -euc '
      TC=/opt/mlp1-toolchain/bin/'"$CROSS"'
      make platform=unix CC="${TC}-gcc" CXX="${TC}-g++" -j"$(nproc)"
      cp '"$ARTIFACT"' /out/'"$ARTIFACT"'
      cp freej2me_plus_libretro.info /out/'"$INFO_ARTIFACT"'
      "${TC}-strip" --strip-unneeded /out/'"$ARTIFACT"'
    '
  echo "$WANT_STAMP" > "$STAMP"
fi

# Docker Desktop can return before a bind-mounted artifact becomes visible to
# the host. Give the mount a brief chance to catch up before declaring failure.
for _ in {1..50}; do
  [ -f "$OUT_DIR/$ARTIFACT" ] && [ -f "$OUT_DIR/$INFO_ARTIFACT" ] && break
  sleep 0.1
done
[ -f "$OUT_DIR/$ARTIFACT" ] || die "build produced no $ARTIFACT"
[ -f "$OUT_DIR/$INFO_ARTIFACT" ] || die "build produced no $INFO_ARTIFACT"

grep -q '^firmware_count = 0' "$OUT_DIR/$INFO_ARTIFACT" \
  || die "$INFO_ARTIFACT still lists system-directory firmware; is the Leaf patch applied?"

ACTUAL_SHA="$(sha256 "$OUT_DIR/$ARTIFACT")"
ACTUAL_INFO_SHA="$(sha256 "$OUT_DIR/$INFO_ARTIFACT")"
echo "build-core: artifact sha256 $ACTUAL_SHA"
echo "build-core: info sha256     $ACTUAL_INFO_SHA"

if [ "$EXPECTED_SHA" = "PENDING-FIRST-VERIFIED-BUILD" ]; then
  echo
  echo "build-core: core.lock.json has no recorded hash yet."
  echo "            Reproduce this build, confirm you get the same hashes, then put"
  echo "            them in core/core.lock.json under artifact.sha256 and info_sha256."
  exit 0
fi

[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] && [ "$ACTUAL_INFO_SHA" = "$EXPECTED_INFO_SHA" ] \
  || die "artifact sha256 mismatch
  built:  $ACTUAL_SHA / $ACTUAL_INFO_SHA
  locked: $EXPECTED_SHA / $EXPECTED_INFO_SHA
A mismatch means the source, the patch, or the toolchain moved. Do not
update the lock without knowing which."

echo "build-core: matches the lock"
