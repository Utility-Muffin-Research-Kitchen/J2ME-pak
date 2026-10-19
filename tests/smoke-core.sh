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
#   5. a core with no jar anywhere reports it and starts nothing;
#   6. the JVM gets the runtime's own C.UTF-8 locale, replacing an inherited
#      LC_ALL and LOCPATH, and the locale loads with the device's glibc;
#   7. games open whatever their file names hold: characters that are not
#      ASCII, "+", a bare "%", or a "%20" that is part of the name, also with
#      a .jad beside the jar;
#   8. a MIDlet printing to System.out never lands inside a frame.
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
read -r IMAGE DIGEST PLATFORM CROSS JDK8 JDK8_ROOT < <(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
c = r["container"]
t = json.load(open(sys.argv[2]))["toolchain"]
print(c["image"], c["digest"], c["platform"], t["cross_prefix"], r["inputs"][0]["file"], r["inputs"][0]["root"])
' "$RUNTIME_LOCK" "$LOCK")
IMAGE_REF="${IMAGE%%:*}@${DIGEST}"
# The build's own JDK 8 compiles the test MIDlet for check 8.
[ -f "$BUILD_DIR/downloads/$JDK8" ] || die "no $JDK8 in $BUILD_DIR/downloads; run make runtime first"

docker run --rm --init --platform "$PLATFORM" \
  -v "$PACKAGE":/media/sdcard1/Apps/mlp1/J2ME.pak:ro \
  -v "$REPO_ROOT/tests":/tests:ro \
  -v "$SRC_DIR/src/libretro":/harness-include:ro \
  -v "$BUILD_DIR/downloads/$JDK8":/jdk8.tar.gz:ro \
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
    LD_LIBRARY_PATH=/opt/frontend-libs LC_ALL=POSIX LOCPATH=/nonexistent \
      /tmp/harness "$CORES/freej2me_plus_libretro.so" /tmp/bios init >/tmp/1.out 2>/tmp/1.err \
      || { cat /tmp/1.err; fail "harness init exited non-zero"; }
    expect /tmp/1.out "java_arg=$CORES/jre/bin/java" "bundled java"
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
    expect /tmp/1.out "java_env=LOCPATH=$CORES/jre/lib/locale" "LOCPATH"
    expect /tmp/1.out "java_env=LC_ALL=C.UTF-8" "LC_ALL"
    [ "$(grep -c "^java_env=LOCPATH=" /tmp/1.out)" = 1 ] || fail "inherited LOCPATH kept"
    [ "$(grep -c "^java_env=LC_ALL=" /tmp/1.out)" = 1 ] || fail "inherited LC_ALL kept"
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

    # This image has a C.UTF-8 of its own in /usr/lib/locale, where glibc
    # falls back to when LOCPATH lacks a locale, so the JVM here would find
    # one even without the pak. The MLP1 firmware has nothing there. Load
    # the shipped files with the glibc in the sysroot, the firmware version,
    # with that directory out of the way; the empty LOCPATH shows it is.
    SYSROOT=/opt/mlp1-toolchain/'"$CROSS"'/sysroot
    printf "%s\n" "#include <langinfo.h>" "#include <locale.h>" "#include <stdio.h>" \
      "int main(void) { if (!setlocale(LC_ALL, \"\")) { puts(\"setlocale failed\"); return 1; }" \
      "  puts(nl_langinfo(CODESET)); return 0; }" >/tmp/codeset.c
    /opt/mlp1-toolchain/bin/'"$CROSS"'-gcc -O1 -Wall -Werror -o /tmp/codeset /tmp/codeset.c
    mkdir -p /tmp/no-locales
    mv /usr/lib/locale /usr/lib/locale.image
    codeset() { env -i LOCPATH="$1" LC_ALL=C.UTF-8 "$SYSROOT/lib/ld-linux-aarch64.so.1" \
      --library-path "$SYSROOT/lib" /tmp/codeset || true; }
    [ "$(codeset "$CORES/jre/lib/locale")" = UTF-8 ] \
      || fail "the shipped locale does not load: $(codeset "$CORES/jre/lib/locale")"
    [ "$(codeset /tmp/no-locales)" = "setlocale failed" ] \
      || fail "the sysroot glibc found a C.UTF-8 without the pak: $(codeset /tmp/no-locales)"
    mv /usr/lib/locale.image /usr/lib/locale
    ok "runtime C.UTF-8 locale: selected for the JVM, loads with glibc 2.38"

    # Each game is a MIDlet suite whose manifest is all FreeJ2ME reads before
    # naming the suite in its log. That line means the JVM found and opened
    # the jar. Unpatched, FreeJ2ME URL-decodes the plain path the core sends:
    # "+" becomes a space, "%20" a space too, and a bare "%" ends the JVM
    # without a word in its log.
    jvm_gone() {
      local state
      state=$(sed -n "s/^State:\t\(.\).*/\1/p" /proc/$1/status 2>/dev/null || true)
      [ -z "$state" ] || [ "$state" = Z ]
    }
    open_game() { # <game> <what> [jad]
      local game="$1" what="$2" bios log harness java=
      bios=$(mktemp -d /tmp/bios-XXXXXX)
      log=$bios/freej2me_system/FreeJ2ME.log
      mkdir -p "$(dirname "$game")"
      python3 -I -c "import sys, zipfile
with zipfile.ZipFile(sys.argv[1], \"w\") as z:
    z.writestr(\"META-INF/MANIFEST.MF\", \"Manifest-Version: 1.0\\r\\nMIDlet-Name: Smoke\\r\\nMIDlet-1: Smoke, , Smoke\\r\\n\\r\\n\")
" "$game"
      [ "${3:-}" != jad ] || printf "MIDlet-Name: Smoke\r\nMIDlet-1: Smoke, , Smoke\r\n" >"${game%.jar}.jad"
      LANG=en_US.UTF-8 /tmp/harness "$CORES/freej2me_plus_libretro.so" "$bios" load "$game" \
        >"$bios/out" 2>"$bios/err" &
      harness=$!
      for _ in $(seq 1 1200); do
        grep -q -e "Loading MIDlet: " -e "not found" "$log" 2>/dev/null && break
        kill -0 "$harness" 2>/dev/null || break
        [ -n "$java" ] || java=$(sed -n "s/^java_pid=//p" "$bios/out")
        [ "${java:-0}" != 0 ] && grep -q "^load_game=" "$bios/out" && jvm_gone "$java" && break
        sleep 0.1
      done
      kill -KILL "$harness" 2>/dev/null || true
      wait "$harness" 2>/dev/null || true
      grep -q "Loading MIDlet: Smoke | Main Class: Smoke" "$log" 2>/dev/null \
        || { cat "$bios/out" "$bios/err" "$log" 2>/dev/null; fail "the JVM did not open $what"; }
      expect "$bios/out" "load_game=1" "$what accepted"
      if [ "${3:-}" = jad ]; then
        grep -q "Accompanying JAD found!" "$log" || { cat "$log"; fail "$what: the .jad was not read"; }
      fi
      ok "$what opens"
    }
    open_game "/tmp/Roms/J2ME/游戏 ゲーム 게임/测试 ゲーム 게임.jar" "a game named in Chinese, Japanese and Korean"
    open_game "/tmp/Roms/J2ME/Tetris+ Deluxe.jar" "a game with + in its name"
    open_game "/tmp/Roms/J2ME/100% Fun.jar" "a game with a bare % in its name"
    open_game "/tmp/Roms/J2ME/Space%20Impact.jar" "a game with %20 in its name"
    open_game "/tmp/Roms/J2ME/Bounce+ (Nokia).jar" "a game with + in its name and a .jad beside it" jad

    # tests/midlets/NoisyProbe.java paints #336699 and prints a Diamond Rush
    # key-event line every millisecond. Every frame after the first painted
    # one has to be entirely that colour: a line inside a frame shifts its
    # bytes. On an MLP1 the 0.1.0 jar garbled 1487 of 1800 such frames.
    mkdir -p /tmp/noisy/classes /tmp/bios-noisy
    tar -xzf /jdk8.tar.gz -C /tmp/noisy
    JDK8_BIN=/tmp/noisy/'"$JDK8_ROOT"'/bin
    "$JDK8_BIN/javac" -nowarn -source 1.4 -target 1.4 -cp "$CORES/freej2me_plus-lr.jar" \
      -d /tmp/noisy/classes /tests/midlets/NoisyProbe.java 2>/dev/null \
      || fail "the test MIDlet does not compile"
    printf "%s\n" "Manifest-Version: 1.0" "MIDlet-Name: NoisyProbe" "MIDlet-Vendor: UMRK test" \
      "MIDlet-Version: 1.0" "MIDlet-1: NoisyProbe, , NoisyProbe" \
      "MicroEdition-Configuration: CLDC-1.1" "MicroEdition-Profile: MIDP-2.0" >/tmp/noisy/manifest.mf
    (cd /tmp/noisy/classes && "$JDK8_BIN/jar" cfm /tmp/noisy/NoisyProbe.jar /tmp/noisy/manifest.mf *.class)
    /tmp/harness "$CORES/freej2me_plus_libretro.so" /tmp/bios-noisy run /tmp/noisy/NoisyProbe.jar 300 336699 \
      >/tmp/8.out 2>/tmp/8.err || { cat /tmp/8.out /tmp/8.err; fail "run harness exited non-zero"; }
    expect /tmp/8.out "load_game=1" "noisy MIDlet accepted"
    grep -q "^first_good=[1-9]" /tmp/8.out || { cat /tmp/8.out; fail "the MIDlet never showed a clean frame"; }
    expect /tmp/8.out "frames_bad=0" "frames garbled by a MIDlet printing to System.out"
    ok "a MIDlet printing to System.out: $(sed -n "s/^frames_good=//p" /tmp/8.out) clean frames, none garbled"

    echo "PASS smoke-core"
  '
