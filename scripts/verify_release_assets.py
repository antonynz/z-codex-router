#!/usr/bin/env python3
"""Verify the exact public Release asset set before publication."""
from __future__ import annotations

import argparse
import hashlib
import json
import tarfile
from pathlib import Path, PurePosixPath


PLATFORMS = [
    ("darwin", "amd64", ""),
    ("darwin", "arm64", ""),
    ("linux", "amd64", ""),
    ("linux", "arm64", ""),
    ("windows", "amd64", ".exe"),
    ("windows", "arm64", ".exe"),
]
ARCHIVES = {
    f"z-codex-router-{platform}-{arch}.tar.gz"
    for platform, arch, _ in PLATFORMS
}
SUPPORT = {"install.sh", "install.ps1", "AGENT_INSTALL.md"}
EXPECTED = ARCHIVES | SUPPORT | {"SHA256SUMS"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_sums(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line in path.read_text().splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            raise SystemExit(f"invalid SHA256SUMS line: {line!r}")
        digest, name = parts
        name = name.removeprefix("*")
        if (
            len(digest) != 64
            or any(character not in "0123456789abcdefABCDEF" for character in digest)
            or name in entries
        ):
            raise SystemExit(f"invalid or duplicate SHA256SUMS entry: {line!r}")
        entries[name] = digest.lower()
    return entries


def verify_archive(path: Path, platform: str, arch: str, suffix: str) -> None:
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)):
            raise SystemExit(f"duplicate archive path in {path.name}")
        for member in members:
            pure = PurePosixPath(member.name)
            if (
                pure.is_absolute()
                or ".." in pure.parts
                or "\\" in member.name
                or not (member.isfile() or member.isdir())
            ):
                raise SystemExit(f"unsafe archive member in {path.name}: {member.name}")
        required = {
            ".agents/plugins/marketplace.json",
            "plugins/z-codex-router/.codex-plugin/plugin.json",
            "plugins/z-codex-router/release/manifest.json",
            f"plugins/z-codex-router/bin/routerctl-{platform}-{arch}{suffix}",
        }
        missing = required - set(names)
        if missing:
            raise SystemExit(f"{path.name} missing {sorted(missing)}")
        binaries = [
            name
            for name in names
            if name.startswith("plugins/z-codex-router/bin/routerctl-")
        ]
        if binaries != [f"plugins/z-codex-router/bin/routerctl-{platform}-{arch}{suffix}"]:
            raise SystemExit(f"{path.name} contains unexpected binaries: {binaries}")
        manifest_file = archive.extractfile(
            "plugins/z-codex-router/release/manifest.json"
        )
        plugin_file = archive.extractfile(
            "plugins/z-codex-router/.codex-plugin/plugin.json"
        )
        if manifest_file is None or plugin_file is None:
            raise SystemExit(f"{path.name} manifests are not regular files")
        manifest = json.load(manifest_file)
        plugin = json.load(plugin_file)
        if manifest.get("version") != "1.0.2" or plugin.get("version") != "1.0.2":
            raise SystemExit(f"{path.name} is not version 1.0.2")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    directory = args.directory

    actual = {path.name for path in directory.iterdir() if path.is_file()}
    if actual != EXPECTED:
        raise SystemExit(
            f"release assets differ: missing={sorted(EXPECTED - actual)} "
            f"unexpected={sorted(actual - EXPECTED)}"
        )
    entries = parse_sums(directory / "SHA256SUMS")
    expected_summed = EXPECTED - {"SHA256SUMS"}
    if set(entries) != expected_summed:
        raise SystemExit(
            f"checksum entries differ: missing={sorted(expected_summed - set(entries))} "
            f"unexpected={sorted(set(entries) - expected_summed)}"
        )
    for name, expected in entries.items():
        path = directory / name
        if path.stat().st_size == 0 or sha256(path) != expected:
            raise SystemExit(f"checksum or size mismatch: {name}")
    for platform, arch, suffix in PLATFORMS:
        verify_archive(
            directory / f"z-codex-router-{platform}-{arch}.tar.gz",
            platform,
            arch,
            suffix,
        )
    if not (directory / "install.sh").stat().st_mode & 0o111:
        raise SystemExit("install.sh is not executable")
    print("Release assets: OK")


if __name__ == "__main__":
    main()
