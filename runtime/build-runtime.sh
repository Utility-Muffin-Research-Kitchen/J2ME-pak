#!/usr/bin/env bash
# Build freej2me_plus-lr.jar and the trimmed Java runtime that ship beside the
# core.
#
# Self-contained like core/build-core.sh: the inputs are three archives pinned
# by sha256 in runtime/runtime.lock.json and the digest-pinned toolchain image,
# run as linux/arm64 because the shipped JDK is aarch64 and the CDS dump has to
# execute it.
#
#   ./runtime/build-runtime.sh            build into build/, verify against the lock
#   FORCE=1 ./runtime/build-runtime.sh    rebuild even if the outputs are present
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/runtime/runtime.lock.json"
CORE_LOCK="$REPO_ROOT/core/core.lock.json"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
DOWNLOADS="$BUILD_DIR/downloads"
WORK="$BUILD_DIR/runtime-work"
OUT_DIR="$BUILD_DIR/runtime"

die() { echo "build-runtime: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v patch >/dev/null 2>&1 || die "patch is required"

lock_get() {
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    d = d[int(key)] if isinstance(d, list) else d[key]
print(" ".join(d) if isinstance(d, list) else d)' "${2:-$LOCK}" "$1"
}

sha256() {
  python3 -c 'import hashlib,sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for block in iter(lambda: f.read(1 << 20), b""):
        h.update(block)
print(h.hexdigest())' "$1"
}

SOURCE_COMMIT="$(lock_get source_commit)"
[ "$SOURCE_COMMIT" = "$(lock_get source.commit "$CORE_LOCK")" ] \
  || die "runtime.lock.json and core.lock.json pin different FreeJ2ME-Plus commits"

PATCH_FILE="$REPO_ROOT/$(lock_get patch.file)"
EXPECTED_PATCH_SHA="$(lock_get patch.sha256)"
[ "$(sha256 "$PATCH_FILE")" = "$EXPECTED_PATCH_SHA" ] \
  || die "patch sha256 mismatch: $(sha256 "$PATCH_FILE")"

IMAGE="$(lock_get container.image)"
IMAGE_REF="${IMAGE%%:*}@$(lock_get container.digest)"
PLATFORM="$(lock_get container.platform)"
JAR="$(lock_get jar.file_name)"
ANT_TARGET="$(lock_get jar.ant_target)"
EXPECTED_JAR_SHA="$(lock_get jar.sha256)"
MODULES="$(lock_get runtime.modules | tr ' ' ',')"
JLINK_OPTIONS="$(lock_get runtime.jlink_options)"
JRE="$(lock_get runtime.directory)"
EXPECTED_TREE_SHA="$(lock_get runtime.tree_sha256)"
CDS_FILE="$(lock_get runtime.cds_file)"

input() { lock_get "inputs.$1.$2"; }
JDK8="$(input 0 file)"
ANT="$(input 1 file)"
JDK17="$(input 2 file)"
JDK8_ROOT="$(input 0 root)"
ANT_ROOT="$(input 1 root)"
JDK17_ROOT="$(input 2 root)"
JDK17_SOURCE="$(input 2 release_source)"

fetch_input() {
  local index="$1" file url expected actual
  file="$(input "$index" file)"
  url="$(input "$index" url)"
  expected="$(input "$index" sha256)"
  mkdir -p "$DOWNLOADS"
  if [ ! -f "$DOWNLOADS/$file" ]; then
    echo "build-runtime: downloading $url"
    curl -fsSL --retry 3 -o "$DOWNLOADS/$file.part" "$url"
    mv "$DOWNLOADS/$file.part" "$DOWNLOADS/$file"
  fi
  actual="$(sha256 "$DOWNLOADS/$file")"
  [ "$actual" = "$expected" ] || die "$file sha256 mismatch
  got:    $actual
  locked: $expected
Delete the file and retry if the download was interrupted; otherwise the
upstream archive changed and the lock must not be updated blindly."
}

if [ -f "$OUT_DIR/$JAR" ] && [ -x "$OUT_DIR/$JRE/bin/java" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "build-runtime: jar and runtime already present (FORCE=1 to rebuild)"
else
  for index in 0 1 2; do fetch_input "$index"; done

  SRC_DIR="$("$REPO_ROOT/scripts/fetch-source.sh")"

  # Build from the pinned commit itself, never the working tree the core
  # build patches. build.xml excludes src/libretro anyway; this makes it
  # structural rather than incidental.
  rm -rf "${WORK:?}" "${OUT_DIR:?}"
  mkdir -p "$WORK/src" "$WORK/out" "$OUT_DIR"
  git -C "$SRC_DIR" archive --format=tar "$SOURCE_COMMIT" | tar -x -C "$WORK/src"

  # The core writes the ROM path into the jar's stdin as raw file-system bytes,
  # and Libretro.java decodes them with the JVM default charset. The core pins
  # that to ISO-8859_1, so the UTF-8 bytes of a non-ASCII name become mojibake
  # and File.isFile() fails. Decode that one string as UTF-8 instead.
  patch -p1 -d "$WORK/src" < "$PATCH_FILE"

  echo "build-runtime: building jar and runtime in $IMAGE_REF ($PLATFORM)"
  docker run --rm --platform "$PLATFORM" \
    -v "$DOWNLOADS":/downloads:ro \
    -v "$REPO_ROOT/scripts":/scripts:ro \
    -v "$WORK":/work \
    "$IMAGE_REF" \
    /bin/sh -euc '
      mkdir -p /opt/java
      cd /opt/java
      tar -xzf /downloads/'"$JDK8"'
      tar -xzf /downloads/'"$ANT"'
      tar -xzf /downloads/'"$JDK17"'
      JDK8_HOME=/opt/java/'"$JDK8_ROOT"'
      ANT_HOME=/opt/java/'"$ANT_ROOT"'
      JDK17_HOME=/opt/java/'"$JDK17_ROOT"'

      # The shipped runtime has to be the build whose source make dist-source
      # publishes. Its release file names that source; jlink drops the line.
      grep -qxF "SOURCE=\"'"$JDK17_SOURCE"'\"" "$JDK17_HOME/release" || {
        echo "build-runtime: $JDK17_HOME/release does not name source '"$JDK17_SOURCE"'" >&2
        exit 1
      }

      cd /work/src
      JAVA_HOME="$JDK8_HOME" "$ANT_HOME/bin/ant" -noinput -buildfile build.xml '"$ANT_TARGET"'
      python3 -I /scripts/normalize-jar.py build/'"$JAR"' /work/out/'"$JAR"'

      "$JDK17_HOME/bin/jlink" \
        --module-path "$JDK17_HOME/jmods" \
        --add-modules '"$MODULES"' \
        '"$JLINK_OPTIONS"' \
        --output /work/out/jre-linked

      # The default CDS archive, from jlink'"'"'s own class list. Its warnings
      # about classes outside this module set are expected.
      /work/out/jre-linked/bin/java -Xshare:dump -Xmx128M -Xms128M -Xlog:disable -Xlog:all=error:stderr
      test -f /work/out/jre-linked/'"$CDS_FILE"'

    '

  # Docker Desktop can return before bind-mounted outputs are visible.
  for _ in {1..50}; do
    [ -f "$WORK/out/$JAR" ] && [ -f "$WORK/out/jre-linked/$CDS_FILE" ] && break
    sleep 0.1
  done

  cp "$WORK/out/$JAR" "$OUT_DIR/$JAR"
  python3 "$REPO_ROOT/scripts/tree-hash.py" flatten "$WORK/out/jre-linked" "$OUT_DIR/$JRE"
fi

[ -f "$OUT_DIR/$JAR" ] || die "build produced no $JAR"
[ -x "$OUT_DIR/$JRE/bin/java" ] || die "build produced no executable $JRE/bin/java"
[ -f "$OUT_DIR/$JRE/$CDS_FILE" ] || die "runtime has no CDS archive"
[ -d "$OUT_DIR/$JRE/legal" ] || die "runtime has no legal/ notices"
if [ "$(lock_get runtime.modules | tr ' ' '\n' | sort | tr '\n' ' ')" != \
     "$(python3 -c 'import sys
for line in open(sys.argv[1]):
    if line.startswith("MODULES="):
        mods = set(line.split("=", 1)[1].strip().strip("\"").split())
roots = mods - {"java.datatransfer", "java.prefs", "java.xml"}
print(" ".join(sorted(roots)) + " ")' "$OUT_DIR/$JRE/release")" ]; then
  die "runtime modules differ from the lock: $(grep '^MODULES=' "$OUT_DIR/$JRE/release")"
fi

JAR_SHA="$(sha256 "$OUT_DIR/$JAR")"
# The CDS archive is not reproducible in JDK 17; see runtime.cds_note.
read -r TREE_SHA TREE_SIZE < <(python3 "$REPO_ROOT/scripts/tree-hash.py" hash "$OUT_DIR/$JRE" --exclude "$CDS_FILE")
CDS_SIZE="$(python3 -c 'import os,sys;print(os.path.getsize(sys.argv[1]))' "$OUT_DIR/$JRE/$CDS_FILE")"
echo "build-runtime: jar sha256      $JAR_SHA"
echo "build-runtime: runtime sha256  $TREE_SHA ($TREE_SIZE bytes, plus $CDS_SIZE bytes of CDS archive)"

if [ "$EXPECTED_JAR_SHA" = "PENDING-FIRST-VERIFIED-BUILD" ] || \
   [ "$EXPECTED_TREE_SHA" = "PENDING-FIRST-VERIFIED-BUILD" ]; then
  echo
  echo "build-runtime: runtime.lock.json has no recorded hashes yet."
  echo "               Reproduce this build, confirm you get the same values, then"
  echo "               put them in jar.sha256 and runtime.tree_sha256."
  exit 0
fi

[ "$JAR_SHA" = "$EXPECTED_JAR_SHA" ] && [ "$TREE_SHA" = "$EXPECTED_TREE_SHA" ] \
  || die "sha256 mismatch
  built:  jar $JAR_SHA, runtime $TREE_SHA
  locked: jar $EXPECTED_JAR_SHA, runtime $EXPECTED_TREE_SHA
A mismatch means an input or the image moved. Do not update the lock
without knowing which."

echo "build-runtime: matches the lock"
