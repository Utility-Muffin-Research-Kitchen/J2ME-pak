#!/usr/bin/env python3
"""Rewrite a jar so its bytes depend only on its contents.

Ant's <jar> stores entries in directory-scan order with the class files'
modification times, so two builds of the same commit differ. This keeps every
entry's bytes, puts META-INF/ and the manifest first (where JarInputStream
expects them) and the rest in byte order, and gives everything one fixed
timestamp and mode.

    normalize-jar.py <input.jar> <output.jar>
"""
from __future__ import annotations

import sys
import zipfile

FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def order(name: str) -> tuple[int, bytes]:
    if name == "META-INF/":
        return (0, b"")
    if name == "META-INF/MANIFEST.MF":
        return (1, b"")
    return (2, name.encode("utf-8"))


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source, target = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(source) as jar:
        names = [info.filename for info in jar.infolist()]
        if len(set(names)) != len(names):
            raise SystemExit(f"{source}: duplicate entries")
        if "META-INF/MANIFEST.MF" not in names:
            raise SystemExit(f"{source}: no manifest")
        with zipfile.ZipFile(target, "w") as out:
            for name in sorted(names, key=order):
                entry = zipfile.ZipInfo(name, FIXED_TIME)
                entry.create_system = 3
                if name.endswith("/"):
                    entry.external_attr = (0o40755 << 16) | 0x10
                    entry.compress_type = zipfile.ZIP_STORED
                    out.writestr(entry, b"")
                else:
                    entry.external_attr = 0o100644 << 16
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    out.writestr(entry, jar.read(name), compresslevel=9)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
