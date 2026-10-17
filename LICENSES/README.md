# Licensing

The components in this repository are not under one licence. Read this before
redistributing the built pak.

| What | Licence | Where |
| --- | --- | --- |
| The FreeJ2ME-Plus libretro core (`cores/freej2me_plus_libretro.so`) | **GPL-3.0-or-later** | `CORE-LICENSE.txt` |
| The FreeJ2ME-Plus jar (`cores/freej2me_plus-lr.jar`) | **GPL-3.0-or-later** | `CORE-LICENSE.txt` |
| ObjectWeb ASM, compiled into the jar | BSD-3-Clause | the second half of `CORE-LICENSE.txt` |
| JLayer, compiled into the jar | LGPL-2.1 | upstream README; headers in `src/javazoom/` |
| MascotME (MascotCapsule V3 renderer), compiled into the jar | MIT | upstream README; headers in its sources |
| The Java runtime (`cores/jre/`), Azul Zulu 17 built from OpenJDK | **GPL-2.0-only WITH Classpath-exception-2.0** | `RUNTIME-LICENSE.txt`; in the package `cores/jre/legal/` per module |
| Third-party code inside the runtime (FreeType, HarfBuzz, libpng, libjpeg, giflib, Little CMS, ICU data, ...) | Various | `cores/jre/legal/<module>/*.md` in the package |
| This repository's build system, manifests, scripts | MIT (see `REPO-LICENSE.txt`) | - |
| `pak/art/J2ME.png` | CC BY-SA 4.0 | `../pak/art/LICENSE-ASSETS.md` |

The package keeps the runtime's `legal/` directory exactly as jlink wrote it,
except that jlink's links between duplicate notices are replaced by copies:
the pak has to survive FAT32 and a zip round trip.

The JDK 8 and Apache Ant used to compile the jar are build tools only. Nothing
from them ships.

## The GPL obligation, concretely

Distributing this pak distributes three GPL binaries: the core, the jar, and
the Java runtime.

**The core and the jar** are covered by construction, the same way the ScummVM
pak covers its core:

- `core/core.lock.json` pins the exact FreeJ2ME-Plus commit, and
  `runtime/runtime.lock.json` checks that the jar is built from the same one.
- `core/leaf.patch` is hash-pinned; it is the only change to that source.
- Both build scripts refuse to package an artifact whose sha256 does not match
  its lock.
- `make dist-source` writes `freej2me-plus-corresponding-source.tar.gz` to
  publish **alongside** the pak: the upstream tree at the pinned commit, the
  patch, both locks, and the build scripts.

**The Java runtime is not covered yet.** It is Azul's Zulu 17.0.20.1 build of
OpenJDK, trimmed with jlink. Azul's `release` file names its source as
`.:git:c8d89ecf367c`, a commit that is not in `openjdk/jdk17u`, and Azul does
not publish a source bundle at a stable URL. Before this pak is published,
decide how to meet the runtime's source obligation: obtain Azul's
corresponding source for that build and publish it beside the pak, or build
the runtime from a public OpenJDK tag instead. A written offer alone is weaker
than shipping the source.

If you fork this repository and change a pin, republish the source for your
pin: the obligation follows the binary you distributed, not the one upstream
currently builds.
