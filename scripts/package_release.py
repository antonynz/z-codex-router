#!/usr/bin/env python3
"""Assemble one platform-specific plugin staging tree and checksum manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import stat
import tarfile
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def archive_filter(member: tarfile.TarInfo) -> tarfile.TarInfo:
    member.uid = 0
    member.gid = 0
    member.uname = ""
    member.gname = ""
    member.mtime = 0
    if member.isdir():
        member.mode = 0o755
    elif member.name.endswith("/scripts/routerctl.sh") or (
        "/bin/routerctl-" in member.name and not member.name.endswith(".exe")
    ):
        member.mode = 0o755
    else:
        member.mode = 0o644
    return member


def create_archive(staging_root: Path, archive_path: Path) -> None:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(staging_root.rglob("*")):
            archive.add(
                path,
                arcname=path.relative_to(staging_root),
                recursive=False,
                filter=archive_filter,
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--platform", choices=["darwin", "linux", "windows"], required=True)
    parser.add_argument("--arch", choices=["amd64", "arm64"], required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()

    if not args.binary.is_file():
        parser.error(f"binary does not exist: {args.binary}")
    if args.platform == "windows" and args.binary.suffix.lower() != ".exe":
        parser.error("a Windows package requires an .exe binary")
    if args.platform != "windows" and args.binary.suffix.lower() == ".exe":
        parser.error("darwin and linux packages require a binary without an .exe suffix")
    if args.out.exists():
        if not args.out.is_dir():
            parser.error(f"output path is not a directory: {args.out}")
        if any(args.out.iterdir()):
            parser.error(f"output directory is not empty: {args.out}")
    if args.archive and args.archive.exists():
        parser.error(f"archive already exists: {args.archive}")
    if args.archive and args.archive.resolve().is_relative_to(args.out.resolve()):
        parser.error("archive path must be outside the staging directory")

    root = Path(__file__).resolve().parents[1]
    plugin = root / "plugins" / "z-codex-router"
    plugin_manifest = json.loads(
        (plugin / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
    )
    release_manifest = json.loads(
        (plugin / "release" / "manifest.json").read_text(encoding="utf-8")
    )
    if plugin_manifest["version"] != release_manifest["version"]:
        parser.error("plugin and release manifest versions differ")
    staging = args.out / "plugins" / "z-codex-router"
    marketplace = root / ".agents" / "plugins" / "marketplace.json"
    marketplace_target = args.out / ".agents" / "plugins" / "marketplace.json"
    shutil.copytree(plugin, staging, ignore=shutil.ignore_patterns("bin"))
    marketplace_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(marketplace, marketplace_target)
    binary_name = f"routerctl-{args.platform}-{args.arch}" + (".exe" if args.platform == "windows" else "")
    target = staging / "bin" / binary_name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.binary, target)
    if args.platform != "windows":
        target.chmod(
            target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        )
    payload = {
        "schemaVersion": 1,
        "version": release_manifest["version"],
        "assets": [{
            "path": f"plugins/z-codex-router/bin/{binary_name}",
            "platform": args.platform,
            "arch": args.arch,
            "sha256": sha256(target),
        }],
    }
    (args.out / "checksums.json").write_text(
        json.dumps(payload, indent=2) + "\n", encoding="utf-8"
    )
    if sha256(args.out / payload["assets"][0]["path"]) != payload["assets"][0]["sha256"]:
        raise SystemExit("packaged binary checksum verification failed")
    if args.archive:
        create_archive(args.out, args.archive)


if __name__ == "__main__":
    main()
