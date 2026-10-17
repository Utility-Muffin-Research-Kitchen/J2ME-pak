#!/usr/bin/env python3
"""Hash a directory tree, or copy it with symlinks replaced by their targets.

    tree-hash.py hash <dir> [--exclude <rel>]...
                                     print the tree sha256 and total size
    tree-hash.py flatten <src> <dst> copy <src> to <dst>, dereferencing links

The hash feeds, for each regular file in byte order of its `/`-joined relative
path:

    rel_utf8 || 0x00 || mode as 4 octal digits || 0x00 || uint64_be(size) || bytes

Mode is part of the hash because an unexecutable bin/java is a broken runtime
with identical bytes. An excluded path must still exist; it is left out of the
hash because its bytes are not reproducible (the CDS archive), not because it
is optional. Any symlink in a hashed tree is an error: the package
has to survive FAT32 and a zip round trip, and neither keeps links.

`flatten` only follows a link whose target resolves inside <src>; jlink writes
its de-duplicated legal notices that way.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import stat
import struct
import sys


def tree_files(root: Path) -> list[tuple[str, Path]]:
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            path = Path(dirpath) / name
            if path.is_symlink():
                raise SystemExit(f"symlink in tree: {path.relative_to(root)}")
        for name in filenames:
            path = Path(dirpath) / name
            if not stat.S_ISREG(path.lstat().st_mode):
                raise SystemExit(f"not a regular file: {path.relative_to(root)}")
            files.append((path.relative_to(root).as_posix(), path))
    files.sort(key=lambda item: item[0].encode("utf-8"))
    return files


def tree_hash(root: Path, exclude: set[str]) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    files = tree_files(root)
    missing = exclude - {rel for rel, _ in files}
    if missing:
        raise SystemExit(f"excluded paths are missing: {', '.join(sorted(missing))}")
    for rel, path in files:
        if rel in exclude:
            continue
        mode = stat.S_IMODE(path.stat().st_mode)
        data = path.read_bytes()
        total += len(data)
        digest.update(rel.encode("utf-8") + b"\0")
        digest.update(f"{mode:04o}".encode("ascii") + b"\0")
        digest.update(struct.pack(">Q", len(data)))
        digest.update(data)
    return digest.hexdigest(), total


def flatten(source: Path, target: Path) -> None:
    source = source.resolve()
    if target.exists():
        raise SystemExit(f"{target} already exists")
    for dirpath, _, filenames in os.walk(source):
        for name in filenames:
            path = Path(dirpath) / name
            if path.is_symlink():
                resolved = path.resolve()
                if source not in resolved.parents:
                    raise SystemExit(f"link escapes the tree: {path} -> {resolved}")
    shutil.copytree(source, target, symlinks=False)


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "hash":
        rest = sys.argv[3:]
        if len(rest) % 2 or any(flag != "--exclude" for flag in rest[0::2]):
            raise SystemExit(__doc__)
        sha, size = tree_hash(Path(sys.argv[2]), set(rest[1::2]))
        print(sha, size)
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "flatten":
        flatten(Path(sys.argv[2]), Path(sys.argv[3]))
        return 0
    raise SystemExit(__doc__)


if __name__ == "__main__":
    raise SystemExit(main())
