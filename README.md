# J2ME content pak

Adds a **J2ME system** to a Leaf device: its own console tile and its own
`Roms/J2ME` folder for Java phone games (`.jar` and `.kjx`). Games run on the
FreeJ2ME-Plus libretro core, and the pak carries the Java runtime that core
needs, so you don't install anything else. It touches nothing that Leaf
manages, and uninstalling it is deleting one directory.

FreeJ2ME-Plus is the work of Paulo Sousa
([AShiningRay](https://github.com/AShiningRay)), David Richardson
([recompileorg](https://github.com/recompileorg)), Saket Dandawate
([hex007](https://github.com/hex007)) and the
[FreeJ2ME-Plus contributors](https://github.com/TASEmulators/freej2me-plus).
This pak builds their code and adds a small patch so it runs from inside a pak.

The repository builds from a clean clone with Docker, `make` and `python3`.
There are no sibling checkouts and no locally built images, and if you find a
`../` in the build system, that is a bug.

```bash
git clone https://github.com/Utility-Muffin-Research-Kitchen/J2ME-pak
cd J2ME-pak
make validate       # fast: check the manifest against the contract
make dist-pakrat    # build the core, jar and runtime, package, hash
make smoke          # run the packaged core in an arm64 container
```

## Putting games in it

Copy your games straight into `Roms/J2ME/`:

```text
Roms/J2ME/
  Snake II.jar
  Bounce.jar
  Some DoJa Game.kjx
```

A J2ME game is a single `.jar`, sometimes with a `.jad` descriptor beside it.
You only need the `.jar`. KDDI games come as `.kjx`. Don't unzip either one:
a `.jar` already is a zip, and the core reads it as it is.

Your saves are kept per game in `Saves/FreeJ2ME-Plus/freej2me/`. FreeJ2ME also
keeps a `freej2me_system/` folder in `BIOS/` for its log and for optional extras
you can add yourself: a TrueType font for games that need one, and a MIDI
SoundFont.

Games are drawn at 240x320 by default. Older Nokia games often want 128x128 or
176x208, and some DoJa games want 240x240. You change it in the FreeJ2ME-Plus
core options.

## What a content pak is

An ordinary `.pak` whose `pak.json` carries a top-level `provides` block. That
block declares systems and the cores that run them, and Leaf merges it into an
effective catalog at scan time.

This one is the **pure** case: it has **no `launch.sh`**, so it isn't listed in
Apps and there is nothing to open. Installing it makes a console tile appear,
not an app.

## What is in the package

```text
J2ME.pak/
  pak.json                         the provides block
  art/J2ME.png                     flat system icon
  cores/freej2me_plus_libretro.so  the patched libretro core
  cores/freej2me_plus-lr.jar       FreeJ2ME-Plus itself
  cores/jre/                       a Java 17 runtime, trimmed to what FreeJ2ME uses
  info/freej2me_plus_libretro.info
  LICENSE-CORE.txt, LICENSE-RUNTIME.txt
```

Upstream's core starts Java from your `PATH` and looks for its jar in
RetroArch's system folder. Leaf shares that folder as `BIOS/`, and the device
has no Java. So the core is patched to look beside itself first: when it finds
`freej2me_plus-lr.jar` and `jre/bin/java` next to its own `.so`, it runs those.
Removing the pak removes all three. The patch also makes sure Java stops when
RetroArch does, even when RetroArch is killed outright.
[`core/PROVENANCE.md`](core/PROVENANCE.md) explains each change.

The runtime is Azul Zulu 17 linked down to three modules, about 93 MB on the
card. [`runtime/PROVENANCE.md`](runtime/PROVENANCE.md) says what was kept and
why.

## Requirements

- An MLP1 on Leaf 0.12.0 or later.
- The stock firmware's fonts. Java draws game text with fontconfig and the Noto
  fonts that ship with the MLP1 firmware; the pak doesn't bundle a font.

## Reproducing the build

Every input is pinned. `core/core.lock.json` names the FreeJ2ME-Plus commit,
the patch and the toolchain image digest. `runtime/runtime.lock.json` names the
JDK 8 and Ant that compile the jar and the Zulu 17 JDK the runtime is linked
from, each by sha256. Both builds refuse to package an artifact whose hash
doesn't match its lock.

| Target | What it does |
| --- | --- |
| `make core` | the patched libretro core, in the pinned toolchain image |
| `make runtime` | the jar and the trimmed runtime, in the same image as `linux/arm64` |
| `make package-mlp1` | assemble `build/package/J2ME.pak` |
| `make dist-pakrat` | zip it to `build/dist/J2ME.mlp1.pak.zip` and print its sha256 |
| `make dist-source` | GPL corresponding source for the core and the jar |
| `make validate` | check `pak/pak.json` against the public content-pak contract |
| `make smoke` | load the packaged core in an arm64 container and check what the patch promises |
| `make check` | validate, package, validate the package strictly, smoke |

The runtime build runs `linux/arm64` containers because the shipped JDK is
aarch64 and building its class-data archive runs it. On an Apple Silicon Mac
that is native. On an x86_64 machine, install QEMU binfmt first.

## Licensing

The core and the jar are GPL-3.0-or-later and the runtime is GPL-2.0 with the
Classpath Exception. [`LICENSES/README.md`](LICENSES/README.md) lists every
component and what publishing this pak obliges you to do, including one item
still open for the runtime.
