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
on this device at all. The patch changes four things, all Linux-only:

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

It also sets `firmware_count = 0` in `freej2me_plus_libretro.info`, because the
jar is no longer something you place in the system directory.

`tests/smoke-core.sh` checks each of these against the packaged core in an
arm64 container, and fails against the unpatched upstream core on the SIGKILL
and failed-exec cases.

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
