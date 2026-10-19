# Core provenance

What is in `freej2me_plus_libretro.so`, where it came from, and how to get the
same bytes again. `core/core.lock.json` is the machine-readable version of this
file and is what the build actually enforces; this one explains it.

## Source

| | |
| --- | --- |
| Upstream | `https://github.com/TASEmulators/freej2me-plus.git` |
| Commit | `baca76a4dda6f30abac67fb4a3db009eed05f91c` (HEAD on 2026-10-17) |
| Directory | `src/libretro` (libretro-common is vendored there, so nothing else is fetched) |
| Licence | GPL-3.0-or-later (`LICENSE` in that tree, copied to `LICENSES/CORE-LICENSE.txt`) |

The same commit is the source of the jar (see `runtime/PROVENANCE.md`). The C
core and the jar speak an unversioned protocol over a pipe, so the two are
never built from different revisions; `runtime/build-runtime.sh` refuses to run
if the locks disagree.

## The Leaf patch

`core/leaf.patch` is hash-pinned beside the commit. Upstream's core runs
`java -jar freej2me_plus-lr.jar` through `PATH` after `chdir()` into
RetroArch's system directory. Leaf points that directory at the shared
`BIOS/` folder, and the MLP1 has no Java, so unpatched the core cannot start
on this device at all. The patch changes seven things, all Linux-only:

1. **Find the bundle beside the core.** `dladdr()` on a function inside the
   core gives the `.so`'s own path. If `freej2me_plus-lr.jar` and an
   executable `jre/bin/java` sit in the same directory, the core runs them by
   absolute path. If either is missing, nothing changes: upstream's
   system-directory check and `execvp("java")` apply as before. The working
   directory is still the system directory, so FreeJ2ME keeps its
   `freej2me_system/` folder (log, custom fonts, SoundFont) in `BIOS/` where
   upstream puts it, outside the pak.
2. **Start the JVM for this frontend.** The bundled `java` gets
   `-Djava.awt.headless=true`, because frames travel over the pipe and there is
   no display server; `-XX:+DisplayVMOutputToStderr -Xlog:disable
   -Xlog:all=warning:stderr`, because stdout *is* that pipe and HotSpot writes
   VM messages and unified-logging warnings (a stale CDS archive, for one) to
   stdout by default; and an absolute jar path. The environment is the
   frontend's with `LD_LIBRARY_PATH` set to `jre/lib/server:jre/lib` ahead of
   whatever the frontend had. `lib/server` leads because the java launcher
   re-executes itself when `LD_LIBRARY_PATH` names a libjvm directory without
   starting with its own. The environment is built before `fork()`, so the
   child only calls `execve()`.
3. **Die with the frontend.** The child calls `prctl(PR_SET_PDEATHSIG,
   SIGKILL)` before exec, then checks `getppid()` in case the parent died
   first. `retro_deinit()` already kills the JVM, but a frontend killed with
   SIGKILL never runs it, and `jawaka-retroarch-runner` escalates to SIGKILL
   by pid, not by process group. Without this the JVM outlives RetroArch,
   holding the audio stream and its heap. The signal follows the thread that
   called `fork()`, RetroArch's main thread, which lives as long as RetroArch.
4. **Never return from a failed exec.** Upstream's child calls
   `retro_deinit()` and returns, so the forked copy of the frontend runs on
   with its stdout on the frame pipe: the parent reads that output as the
   JVM's handshake and treats it as a running app. The patched child calls
   `_exit(127)`.
5. **No JVM, no game.** When the JVM fails to start or exits before its
   handshake, upstream's `retro_init()` shows a message and `retro_load_game()`
   then returns true anyway, so the frontend runs a core with nothing behind
   it and shows a black screen for good. The patched `retro_load_game()`
   returns false when the JVM is not running, and the frontend ends the
   session.
6. **Open games whatever their file name.** Java converts every file name
   through the C library's codeset, and the MLP1 firmware has no compiled
   locales at all, so whatever `LANG` says the JVM runs with
   `sun.jnu.encoding=ANSI_X3.4-1968` and every character outside ASCII
   becomes `?`. A game named in Chinese, Japanese or Korean, or with an
   accented letter, was "not found", and FreeJ2ME quit. A per-game folder with
   such a name could not be created either, because FAT32 refuses `?`. The
   runtime now carries a C.UTF-8 locale (`runtime/PROVENANCE.md`), and the
   child environment selects it with `LOCPATH=jre/lib/locale` and
   `LC_ALL=C.UTF-8`, replacing any inherited value. `LC_ALL`, because an
   inherited `LANG` that names a missing locale makes `setlocale(LC_ALL, "")`
   fail for every category. That alone isn't enough: `Libretro.java` decoded
   the path the core sends with `file.encoding`, which FreeJ2ME uses as the
   game's text encoding (`ISO_8859_1`, `Shift_JIS` or `EUC_KR`), so the
   UTF-8 bytes of the name came back as other characters. The patch decodes
   them with `sun.jnu.encoding`, the exact inverse of what `java.io.File`
   does with the string. `Libretro.java` then URL-decoded the result,
   although the core sends what `realpath()` returns, never a URL: a `+` or
   a `%20` in the name became a space, so `Tetris+ Deluxe.jar` was "not
   found", and a bare `%`, as in `100% Fun.jar`, threw and the JVM quit
   without a word in its log. The patch passes the path on as it is. When a
   `.jad` with the same name sits beside the jar, `MobilePlatform.java` reads
   it from its `file:` URI, and it URL-decoded that URI too, which turned a
   `+` into a space again; the patch lets `URI` decode it instead. The
   runtime build applies the same patch before compiling the jar.
7. **Frames alone on the frame pipe.** The JVM's stdout carries the frames:
   `Libretro.java` writes a 16-byte header and then the pixels, from its I/O
   thread. FreeJ2ME never redirected `System.out`, so whatever a MIDlet
   prints goes into the same pipe, from the MIDlet's own threads. Diamond
   Rush prints `keyPressed:-5` and the like on every key event. A line that
   lands between a header and its pixels shifts the whole frame by its
   length, so the colours rotate (brown bricks turn purple or green) and the
   picture flickers for a frame (J2ME-pak#4). Lines between frames were
   already harmless: the core skips anything before a frame's `0xFE` marker.
   `Libretro.java` now keeps the real stdout in a private stream for the
   handshake and the frames, and `main()` points `System.out` at stderr
   before anything else runs, so a MIDlet's prints reach the session log
   instead. Upstream and the original FreeJ2ME both still write frames
   through `System.out`.

It also sets `firmware_count = 0` in `freej2me_plus_libretro.info`, because the
jar is no longer something you place in the system directory.

### Defaults for a one-stick handheld

These come from playing a dozen real games on the MLP1 and apply on every
platform this patch is built for:

- **Fire on A.** Upstream puts OK/Fire on the RetroPad's Y (west) and 9 on A.
  On a Nintendo-style handheld A is the confirm button, and Fire is the key
  nearly every game wants for menus, "press any key" and shooting, so the two
  swap. The input descriptors follow.
- **LCD backlight off.** Upstream defaults `freej2me_backlightcolor` to Green,
  and at this commit `PlatformGraphics.flushGraphics()` masks every pixel with
  the backlight colour whenever one is set (the `renderLCDMask` check is
  commented out), so every colour game came out green. The Java side's own
  default is Disabled; the core now agrees.
- **Two MIDI synthesizers.** `freej2me_numsynths` defaults to 2 instead of 4.
  Each synthesizer opens its own audio line at startup; on the MLP1 the extra
  two cost about half a second of every launch, around 10 MB of java memory,
  and about a fifth of a core in PulseAudio for as long as the game runs.
  Music in Doom II RPG, Final Fantasy and Galaxy on Fire 2 plays with 2.
- **Pointer Stick.** A new option, `freej2me_pointerstick` (Right Stick by
  default, as upstream), lets the left stick move the pointer, which is how a
  one-stick device reaches games built for touchscreens. While it is set the
  left stick sends no 2, 4, 6 or 8; **L3** still taps while the pointer shows.
  With the left stick the pointer stays up, and **L3** taps, for 3 s (180
  frames) after the stick stops, against upstream's half second: the thumb has
  to leave the stick to reach L3, and on the MLP1 that pause usually ran past
  0.5 s, which turned every tap into a 5. Any other button hides the pointer at
  once, so L3 is the 5 key again straight away. An L3 release always follows
  its press, so a tap still ends as a tap if the pointer hid while L3 was held.
  The right stick keeps upstream's half second.
- **Pointer on the canvas.** Upstream lets the pointer's tip, which is the tap
  position, go one row below the last; a tap there misses the canvas. The
  patch stops it on the last row.

`tests/smoke-core.sh` checks the seven numbered changes against the packaged
core in an arm64 container, and fails against the unpatched upstream core on
the SIGKILL, failed-exec and refused-game cases. For the sixth it loads the
shipped locale with the sysroot's glibc 2.38, and opens games whose names are
in Chinese, Japanese and Korean, hold a `+`, a bare `%` or a `%20`, or have a
`.jad` beside the jar. Without the URL-decoding changes the `+`, `%` and
`%20` games don't open, and without the `MobilePlatform.java` one the game
with a `.jad` doesn't. For the seventh it compiles `tests/midlets/NoisyProbe.java`,
a MIDlet that paints one colour and prints a Diamond Rush line every
millisecond, and requires every frame after the first painted one to be that
colour; the 0.1.0 jar fails it. The defaults were checked on
an MLP1: key codes logged by a test MIDlet, colours read off the screen,
music in three MIDI games, and the left-stick pointer tapping a touch build.
The sixth change was checked on an MLP1 on 2026-10-19 with the smoke test's
harness and the packaged core: a jar named `测试 ゲーム 게임.jar` on the vfat
card loads, and a MIDlet named `探针测试` gets `config/探针测试/`, where 0.1.0
quits with "not found" and fails to create `config/????/`. Fed the same path
directly, the jar also finds it with `-Dfile.encoding=Shift_JIS` and `EUC_KR`,
the encodings the core restarts it with for DoJa and KDDI games.
The seventh was checked on an MLP1 on 2026-10-19 with the same MIDlet through
the harness's `run` mode: of 1800 frames, the 0.1.0 jar sent 2 clean and 1487
garbled ones, starting with the bytes of `key`; this jar sent 1794 clean ones
after its first painted frame and none garbled.

## Toolchain

| | |
| --- | --- |
| Image | `ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain` |
| Digest | `sha256:66aac16fb8b07e663c9b4d66970f272df195a6eba98dfad8286eabbaa617faf9` |
| Compiler | `aarch64-buildroot-linux-gnu-gcc 12.3.0` (Buildroot) |
| Target | aarch64 Cortex-A55, glibc 2.38 (Miniloong Pocket 1, RK3566) |

The **digest** is what the build uses, not the tag.

## Build

```
make platform=unix \
     CC=aarch64-buildroot-linux-gnu-gcc \
     CXX=aarch64-buildroot-linux-gnu-g++ \
     -j$(nproc)
```

in `src/libretro`, then `--strip-unneeded`. `platform=unix` with an explicit
cross compiler is upstream's own Linux recipe. The result links only the C and
C++ runtimes, all present on the device. `dladdr` has been part of glibc
itself since 2.34, so no `-ldl` is needed.

## Artifact

`core.lock.json` carries the sha256 of the stripped `.so` and of the patched
`.info`. `build-core.sh` fails on a mismatch rather than packaging whatever
was produced, and rebuilds when the cached core was built from a different
commit or patch.

### Recording a hash

1. `make core` on a clean checkout. Note the printed sha256.
2. `make distclean && make core`, ideally on another machine. Note it again.
3. If they agree, put it in `core.lock.json`. If they do not, find out why
   before recording either.
