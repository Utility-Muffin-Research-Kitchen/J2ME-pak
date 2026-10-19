#!/usr/bin/env bash
# Off-device smoke test of the packaged core, jar and runtime.
#
# Runs tests/core-harness.c against build/package/J2ME.pak in the pinned image
# as linux/arm64, with the pak mounted where an MLP1 card would put it. It
# checks what core/leaf.patch promises:
#
#   1. the core finds the jar and runtime beside itself and starts the JVM by
#      absolute path, headless, with the JRE's libraries first on
#      LD_LIBRARY_PATH (in an order that spares the java launcher a re-exec)
#      and the frontend's system directory as its cwd;
#   2. retro_deinit() stops it;
#   3. SIGKILL of the frontend takes the JVM with it (PR_SET_PDEATHSIG);
#   4. a core with nothing beside it and no java on PATH fails cleanly, with no
#      second copy of the frontend returning from fork(), and refuses the game;
#   5. a core with no jar anywhere reports it and starts nothing.
#
# The image gets fontconfig and DejaVu from the distribution for this test
# only: the MLP1 firmware provides fontconfig and its Noto fonts, and Java
# cannot start FreeJ2ME without some font. Needs network for that step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
PACKAGE="$BUILD_DIR/package/J2ME.pak"
SRC_DIR="$BUILD_DIR/freej2me-src"
LOCK="$REPO_ROOT/core/core.lock.json"
RUNTIME_LOCK="$REPO_ROOT/runtime/runtime.lock.json"

die() { echo "smoke-core: $*" >&2; exit 1; }

[ -f "$PACKAGE/cores/freej2me_plus_libretro.so" ] || die "no package; run make package-mlp1 first"
[ -f "$SRC_DIR/src/libretro/libretro.h" ] || die "no source checkout; run make core first"

# The arm64 container is the runtime lock's: the linux/arm64 manifest of the
# toolchain index, pinned directly so it never collides with the amd64 variant
# the core build pulled (see the note in runtime.lock.json).
read -r IMAGE DIGEST PLATFORM CROSS < <(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["container"]
t = json.load(open(sys.argv[2]))["toolchain"]
print(c["image"], c["digest"], c["platform"], t["cross_prefix"])
' "$RUNTIME_LOCK" "$LOCK")
IMAGE_REF="${IMAGE%%:*}@${DIGEST}"

docker run --rm --init --platform "$PLATFORM" \
  -v "$PACKAGE":/media/sdcard1/Apps/mlp1/J2ME.pak:ro \
  -v "$REPO_ROOT/tests":/tests:ro \
  -v "$SRC_DIR/src/libretro":/harness-include:ro \
  "$IMAGE_REF" \
  /bin/bash -euo pipefail -c '
    PAK=/media/sdcard1/Apps/mlp1/J2ME.pak
    CORES=$PAK/cores
    fail() { echo "FAIL $*"; exit 1; }
    ok() { echo "ok   $*"; }
    expect() { grep -qxF -- "$2" "$1" || { cat "$1"; fail "$3: missing line: $2"; }; }

    apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      fontconfig fonts-dejavu-core >/dev/null

    /opt/mlp1-toolchain/bin/'"$CROSS"'-gcc -O1 -Wall -Werror -I/harness-include \
      -o /tmp/harness /tests/core-harness.c -ldl

    mkdir -p /tmp/bios /opt/frontend-libs
    LD_LIBRARY_PATH=/opt/frontend-libs \
      /tmp/harness "$CORES/freej2me_plus_libretro.so" /tmp/bios init >/tmp/1.out 2>/tmp/1.err \
      || { cat /tmp/1.err; fail "harness init exited non-zero"; }
    # jre/bin/java is the locale shim: it sets LOCPATH/LANG and execs
    # java.real, so this is the process the core's exec turned into. Reaching
    # it proves the shim ran and kept the argument list intact.
    expect /tmp/1.out "java_arg=$CORES/jre/bin/java.real" "bundled JVM behind the locale shim"
    expect /tmp/1.out "java_arg=-Djava.awt.headless=true" "headless"
    expect /tmp/1.out "java_arg=-XX:+DisplayVMOutputToStderr" "VM output off the pipe"
    expect /tmp/1.out "java_arg=-Xlog:all=warning:stderr" "logging off the pipe"
    expect /tmp/1.out "java_arg=-jar" "-jar"
    expect /tmp/1.out "java_arg=$CORES/freej2me_plus-lr.jar" "absolute jar path"
    expect /tmp/1.out "java_arg=240" "width"
    expect /tmp/1.out "java_arg=320" "height"
    # Exactly this value: the JRE first, then the inherited value, and no
    # prefix added by the java launcher re-executing itself.
    expect /tmp/1.out "java_env=LD_LIBRARY_PATH=$CORES/jre/lib/server:$CORES/jre/lib:/opt/frontend-libs" \
      "LD_LIBRARY_PATH"
    expect /tmp/1.out "java_cwd=/tmp/bios" "cwd is the system directory"
    expect /tmp/1.out "java_after_deinit=gone" "deinit stops the JVM"
    [ "$(grep -c "^after_init=" /tmp/1.out)" = 1 ] || fail "init returned more than once"
    ok "bundled runtime: absolute paths, headless, LD_LIBRARY_PATH, cwd, deinit"

    /tmp/harness "$CORES/freej2me_plus_libretro.so" /tmp/bios init >/tmp/1b.out 2>/tmp/1b.err \
      || { cat /tmp/1b.err; fail "harness init without LD_LIBRARY_PATH exited non-zero"; }
    expect /tmp/1b.out "java_env=LD_LIBRARY_PATH=$CORES/jre/lib/server:$CORES/jre/lib" \
      "LD_LIBRARY_PATH without an inherited value"
    ok "no inherited LD_LIBRARY_PATH: the JRE alone"

    /tmp/harness "$CORES/freej2me_plus_libretro.so" /tmp/bios hold >/tmp/2.out 2>/tmp/2.err &
    HARNESS=$!
    for _ in $(seq 1 300); do grep -q "^holding=1" /tmp/2.out 2>/dev/null && break; sleep 0.1; done
    grep -q "^holding=1" /tmp/2.out || { cat /tmp/2.out /tmp/2.err; fail "hold mode never started"; }
    JAVA=$(sed -n "s/^java_pid=//p" /tmp/2.out)
    [ "${JAVA:-0}" != 0 ] || fail "hold mode started no JVM"
    kill -KILL "$HARNESS"
    wait "$HARNESS" 2>/dev/null || true
    for _ in $(seq 1 50); do
      STATE=$(sed -n "s/^State:\t\(.\).*/\1/p" /proc/$JAVA/status 2>/dev/null || true)
      [ -z "$STATE" ] || [ "$STATE" = Z ] && break
      sleep 0.1
    done
    [ -z "$STATE" ] || [ "$STATE" = Z ] || fail "JVM $JAVA survived SIGKILL of its frontend (state $STATE)"
    ok "SIGKILL of the frontend takes the JVM with it"

    mkdir -p /tmp/lonely /tmp/bios-with-jar
    cp "$CORES/freej2me_plus_libretro.so" /tmp/lonely/
    cp "$CORES/freej2me_plus-lr.jar" /tmp/bios-with-jar/
    command -v java >/dev/null && fail "the image has a java on PATH; the fallback test needs none"
    /tmp/harness /tmp/lonely/freej2me_plus_libretro.so /tmp/bios-with-jar init >/tmp/3.out 2>/tmp/3.err \
      || { cat /tmp/3.err; fail "fallback harness exited non-zero"; }
    [ "$(grep -c "^after_init=" /tmp/3.out)" = 1 ] \
      || { cat /tmp/3.out; fail "a failed exec returned into the frontend"; }
    # Unpatched, the forked copy of the harness survives here as a child and
    # its output on the pipe passes for a started JVM.
    expect /tmp/3.out "java_pid=0" "no child left after a failed exec"
    grep -q "using the system directory and PATH" /tmp/3.err || fail "no fallback log line"
    /tmp/harness /tmp/lonely/freej2me_plus_libretro.so /tmp/bios-with-jar load >/tmp/3b.out 2>/tmp/3b.err \
      || { cat /tmp/3b.err; fail "fallback harness (load) exited non-zero"; }
    # Unpatched, retro_load_game() succeeds with no JVM and the frontend runs
    # on with a black screen.
    expect /tmp/3b.out "load_game=0" "game refused without a running JVM"
    ok "no bundle, no java: fails once, no second frontend, game refused"

    mkdir -p /tmp/empty-bios
    /tmp/harness /tmp/lonely/freej2me_plus_libretro.so /tmp/empty-bios init >/tmp/4.out 2>/tmp/4.err \
      || { cat /tmp/4.err; fail "missing-jar harness exited non-zero"; }
    expect /tmp/4.out "java_pid=0" "no JVM without a jar"
    grep -q "does not exist in the system dir" /tmp/4.err || fail "missing jar not reported"
    ok "no jar anywhere: reported, nothing started"

    echo "PASS smoke-core"
  '
