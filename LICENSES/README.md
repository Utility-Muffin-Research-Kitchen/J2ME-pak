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
| The Java runtime (`cores/jre/`), Eclipse Temurin 17 built from OpenJDK | **GPL-2.0-only WITH Classpath-exception-2.0** | `RUNTIME-LICENSE.txt`; in the package `cores/jre/legal/` per module |
| Third-party code inside the runtime (FreeType, HarfBuzz, libpng, libjpeg, giflib, Little CMS, ICU data, ...) | Various | `cores/jre/legal/<module>/*.md` in the package |
| The bundled `C.utf8` locale (`runtime/overlay/locale/C.utf8/`) | **LGPL-2.1-or-later**, as glibc localedata | `runtime/overlay/locale/README.md` |
| This repository's build system, manifests, scripts | MIT (see `REPO-LICENSE.txt`) | - |
| `pak/art/J2ME.png` | CC BY-SA 4.0 | `../pak/art/LICENSE-ASSETS.md` |
| `pak/art/J2ME-photo.png` (AI-generated render) | No rights claimed | `../pak/art/LICENSE-ASSETS.md` |
| `pak/art/J2ME-wordmark.png`, `pak/art/J2ME-grid.png` | CC0 1.0 (lettering); Lexend font OFL 1.1 | `../pak/art/WORDMARK-SOURCE.md`, `../pak/art/GRID-ICON-SOURCE.md` |

The package keeps the runtime's `legal/` directory exactly as jlink wrote it,
except that jlink's links between duplicate notices are replaced by copies:
the pak has to survive FAT32 and a zip round trip.

The JDK 8 and Apache Ant used to compile the jar are build tools only. Nothing
from them ships.

The bundled `C.utf8` locale is glibc locale data, not code from the runtime: it
is regenerated from glibc's own `localedata/` with the distribution's
`localedef`, and distributed under the LGPL like glibc itself.
`runtime/overlay/locale/README.md` records the release it came from and the
exact command that reproduces it.

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

**The Java runtime** is Eclipse Temurin 17.0.20.1+1, trimmed with jlink.
Adoptium publishes the source of each Temurin release beside its binaries, so
it is covered the same way:

- `runtime/runtime.lock.json` pins the aarch64 JDK and Adoptium's source
  tarball, `OpenJDK17U-jdk-sources_17.0.20.1_1.tar.gz`, by sha256. Both match
  the `.sha256.txt` files Adoptium publishes with them.
- That tarball is the source of that JDK. Adoptium's metadata for both names
  the same `adoptium/jdk17u` commit (`79597447bd94ff9f8216e2e3a573d5261ee49f2e`,
  tag `jdk-17.0.20.1+1_adopt`) and the same `temurin-build` scripts commit.
  The JDK's own `release` file names that commit too, and the build refuses a
  JDK whose `release` file says otherwise.
- jlink only selects and links modules from that JDK; it adds no code of its
  own. The source of the whole JDK covers the trimmed runtime.
- `make dist-source` checks the tarball against the lock and copies it to
  `build/dist/` beside the pak, to publish **alongside** it.

If you fork this repository and change a pin, republish the source for your
pin: the obligation follows the binary you distributed, not the one upstream
currently builds.
