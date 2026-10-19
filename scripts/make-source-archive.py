#!/usr/bin/env python3
"""Create the GPL corresponding-source archive for the core and the jar.

Both come from one FreeJ2ME-Plus commit. The archive holds that commit's tree
exactly as upstream published it, the hash-pinned Leaf patch both builds
apply, both locks, and every script the two builds run, so the shipped core
and jar can be rebuilt from it. The Java runtime's source is Adoptium's own tarball,
which `make dist-source` publishes beside this one.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

BUILD_FILES = (
    "Makefile",
    "core/build-core.sh",
    "runtime/build-runtime.sh",
    "scripts/fetch-source.sh",
    "scripts/normalize-jar.py",
    "scripts/tree-hash.py",
)


def git_head(repo: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
    ).strip()


def add_git_archive(output: tarfile.TarFile, repo: Path, commit: str,
                    prefix: str) -> None:
    process = subprocess.Popen(
        ["git", "-C", str(repo), "archive", "--format=tar", commit],
        stdout=subprocess.PIPE,
    )
    assert process.stdout is not None
    with tarfile.open(fileobj=process.stdout, mode="r|") as source:
        for member in source:
            member.name = prefix + member.name
            fileobj = source.extractfile(member) if member.isfile() else None
            output.addfile(member, fileobj)
    if process.wait() != 0:
        raise SystemExit(f"git archive failed for {repo}")


def add_bytes(output: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.mtime = 0
    output.addfile(info, io.BytesIO(data))


def checked_bytes(path: Path, expected: str) -> bytes:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(f"sha256 mismatch for {path}: {actual}, lock requires {expected}")
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path, help="this repository")
    parser.add_argument("--source", required=True, type=Path, help="the FreeJ2ME-Plus checkout")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    repo_root = args.repo.resolve()
    core_lock_path = repo_root / "core" / "core.lock.json"
    runtime_lock_path = repo_root / "runtime" / "runtime.lock.json"
    core_lock = json.loads(core_lock_path.read_text(encoding="utf-8"))
    runtime_lock = json.loads(runtime_lock_path.read_text(encoding="utf-8"))

    commit = core_lock["source"]["commit"]
    if runtime_lock["source_commit"] != commit:
        raise SystemExit("core and runtime locks pin different FreeJ2ME-Plus commits")
    if not (args.source / ".git").exists():
        raise SystemExit(f"missing source checkout: {args.source}; run the build first")
    if git_head(args.source) != commit:
        raise SystemExit(f"source checkout {args.source} is not at {commit}")

    root = f"freej2me-plus-{commit}"
    patch_file = core_lock["patch"]["file"]
    patch = checked_bytes(repo_root / patch_file, core_lock["patch"]["sha256"])

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|") as output:
                add_git_archive(output, args.source, commit, f"{root}/")
                add_bytes(output, f"{root}/leaf/{patch_file}", patch)
                add_bytes(output, f"{root}/leaf/core/core.lock.json", core_lock_path.read_bytes())
                add_bytes(output, f"{root}/leaf/runtime/runtime.lock.json", runtime_lock_path.read_bytes())
                for rel in BUILD_FILES:
                    path = repo_root / rel
                    mode = 0o755 if rel.endswith((".sh", ".py")) else 0o644
                    add_bytes(output, f"{root}/leaf/{rel}", path.read_bytes(), mode)
                add_bytes(output, f"{root}/leaf/README.txt", (
                    "The tree above this directory is FreeJ2ME-Plus at commit\n"
                    f"{commit}, unmodified.\n\n"
                    "The libretro core shipped in the J2ME pak is built from it with\n"
                    f"{patch_file} applied (see core/build-core.sh). The jar is built\n"
                    "from it with the same patch applied, using Apache Ant and JDK 8,\n"
                    "then normalized by scripts/normalize-jar.py (see\n"
                    "runtime/build-runtime.sh). The locks name every input by sha256.\n"
                ).encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
