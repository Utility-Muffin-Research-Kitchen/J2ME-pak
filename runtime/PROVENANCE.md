# Jar and Java runtime provenance

What ships beside the core in `cores/`, where it came from, and how to get the
same bytes again. `runtime/runtime.lock.json` is what the build enforces.

```text
cores/freej2me_plus_libretro.so   the patched core (core/PROVENANCE.md)
cores/freej2me_plus-lr.jar        FreeJ2ME-Plus, libretro build
cores/jre/                        Java 17 runtime, trimmed with jlink
```

## The jar

Upstream `build.xml`, target `jar-libretro`, at the same commit as the core
(`baca76a4dda6f30abac67fb4a3db009eed05f91c`), built from `git archive` of that
commit rather than the patched working tree.

`build.xml` compiles for Java 1.5 against `${java.home}/lib/rt.jar`, which only
a JDK 8 has, and upstream CI builds with JDK 8. So the jar is compiled with
**Zulu 8.96.0.205 (OpenJDK 8u504)** and **Apache Ant 1.10.18**, both pinned by
sha256 and both build tools only. The class files target Java 5 and run on the
shipped Java 17 runtime.

Ant writes entries in directory-scan order with build-time timestamps.
`scripts/normalize-jar.py` rewrites the jar inside the pinned image: manifest
first, everything else in byte order, one fixed timestamp, the image's zlib.
Two builds of the same commit then give the same bytes.

## The runtime

**Azul Zulu 17.68.203 (OpenJDK 17.0.20.1+1)** for linux aarch64, from Azul's
CDN, pinned by sha256. Its own `jlink` links its own `jmods`:

```
jlink --add-modules java.base,java.desktop,jdk.charsets \
      --strip-java-debug-attributes --no-header-files --no-man-pages \
      --compress=0
```

### Why these modules

| Module | Why |
| --- | --- |
| `java.base` | everything |
| `java.desktop` | AWT imaging (`BufferedImage`, `Graphics2D`, fonts), `javax.imageio`, `javax.sound.sampled` and `javax.sound.midi` with the Gervill synthesizer. Pulls in `java.datatransfer`, `java.prefs` and `java.xml`. |
| `jdk.charsets` | FreeJ2ME names `Shift_JIS`, `EUC_KR` and `Big5` by string, and the core's text-encoding option passes `-Dfile.encoding=Shift_JIS` or `EUC_KR`. None of those are in `java.base`. jdeps can't see string lookups, so it doesn't list this one. |

`jdeps --print-module-deps` on the jar reports `java.base,java.desktop`.
The jar carries its own copies of some `javax.xml` and `org.w3c.dom` classes;
`java.xml` shadows them, as it does on any desktop JDK 9 or later.

### Size

| Variant | Size |
| --- | --- |
| Shipped: uncompressed, with CDS | 93.0 MB (81.4 MB + 11.7 MB `classes.jsa`) |
| `--compress=2`, no CDS | 54 MB |
| Full Zulu 17 JRE as other packs ship it | about 138 MB |

`--compress=0` is deliberate: a compressed module image inflates every class
it loads, on a Cortex-A55. The download is a zip either way. Whether the
smaller image is worth its startup cost is for device measurement to settle.

### CDS

`lib/server/classes.jsa` is the default class-data-sharing archive, dumped
after linking with `java -Xshare:dump -Xmx128M -Xms128M`, which is how OpenJDK's
own build makes it. jlink's `--generate-cds-archive` would also write
`classes_nocoops.jsa`, which applies only to heaps over 32 GB.

JDK 17 does not dump this archive byte-for-byte reproducibly here (about 20
bytes vary between dumps of the same tree). It is a cache of classes already
in `lib/modules`, so the locked tree hash leaves it out and the build only
requires that it exists. The JVM checks it against the JVM build and the size
of `lib/modules` at startup, and ignores it if they don't match.

### FAT32 safety

jlink writes the per-module legal notices that duplicate `java.base`'s as
symlinks. `scripts/tree-hash.py flatten` replaces them with copies, and the
tree hash refuses any symlink, so the package survives FAT32 and a zip round
trip. File modes are part of the hash: an unexecutable `bin/java` is a broken
runtime with identical bytes.

### Fonts

Nothing font-related is bundled. FreeJ2ME draws text with Java's logical
fonts, and on Linux Java resolves those through fontconfig. The MLP1 stock
firmware ships `libfontconfig.so.1` and Noto Sans, including the SC and KR
families, under `/secord/fonts`. That covers Japanese and Korean games too.

This is a hard dependency. With no fontconfig and no fonts, the JVM fails
before its handshake with `Fontconfig head is null` and keeps running, so the
core would wait for it indefinitely. A device that lacks fontconfig needs a
bundled font and a `fontconfig.properties` before this pak can support it.

### Audio

FreeJ2ME plays sound itself through `javax.sound` on ALSA's `default` PCM, not
through libretro. On the MLP1 that PCM is the libasound PulseAudio plugin, and
RetroArch uses PulseAudio natively, so both streams mix in the same daemon and
follow the launcher's volume. Bluetooth output goes through BlueALSA instead,
and is untested.

## Corresponding source

The jar is covered by `make dist-source` together with the core. The runtime
is not covered yet; see `LICENSES/README.md`.
