#!/usr/bin/env python3
"""Offline fixtures for the POSIX bootstrap plus optional native-package lifecycle."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
ASSET_PREFIX = "z-codex-router"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def make_fake_tools(root: Path) -> Path:
    tools = root / "tools"
    tools.mkdir()
    write_executable(
        tools / "curl",
        """#!/bin/sh
set -eu
destination=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) destination=$2; shift 2 ;;
    --*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -n "$destination" ] && [ -n "$url" ] || exit 2
asset=${url##*/}
source=$ZCR_FIXTURE_DIR/$asset
[ -f "$source" ] || exit 22
cp "$source" "$destination"
""",
    )
    write_executable(
        tools / "codex",
        """#!/bin/sh
set -eu
printf '%s|%s\n' "${CODEX_HOME:-}" "$*" >> "$ZCR_TEST_CODEX_LOG"
printf '{"ok":true}\n'
""",
    )
    return tools


def make_staging(root: Path, platform: str, arch: str, version: str) -> Path:
    staging = root / "staging"
    plugin = staging / "plugins" / "z-codex-router"
    (staging / ".agents" / "plugins").mkdir(parents=True)
    (staging / ".agents" / "plugins" / "marketplace.json").write_text(
        json.dumps(
            {
                "name": "z-codex-router",
                "plugins": [
                    {
                        "name": "z-codex-router",
                        "source": {
                            "source": "local",
                            "path": "./plugins/z-codex-router",
                        },
                        "policy": {
                            "installation": "AVAILABLE",
                            "authentication": "ON_INSTALL",
                        },
                        "category": "Productivity",
                    }
                ],
            }
        )
        + "\n"
    )
    (plugin / ".codex-plugin").mkdir(parents=True)
    (plugin / ".codex-plugin" / "plugin.json").write_text(
        json.dumps(
            {
                "name": "z-codex-router",
                "version": version,
                "description": "fixture",
                "author": {"name": "fixture"},
                "interface": {
                    "displayName": "fixture",
                    "shortDescription": "fixture",
                    "longDescription": "fixture",
                    "developerName": "fixture",
                    "category": "Productivity",
                    "capabilities": ["Validation"],
                },
            }
        )
        + "\n"
    )
    (plugin / "release").mkdir()
    (plugin / "release" / "manifest.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "version": version,
                "channel": "stable",
                "payloadSha256": "0" * 64,
            },
            indent=2,
        )
        + "\n"
    )
    (plugin / "bin").mkdir()
    binary = plugin / "bin" / f"routerctl-{platform}-{arch}"
    write_executable(binary, "#!/bin/sh\nexit 0\n")
    write_executable(
        plugin / "scripts" / "routerctl.sh",
        """#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$ZCR_TEST_ROUTER_LOG"
printf '{"ok":true,"code":"OK"}\n'
""",
    )
    (staging / "checksums.json").write_text("{}\n")
    return staging


def build_archive(
    fixture: Path,
    platform: str = "darwin",
    arch: str = "arm64",
    version: str = "1.0.0",
    unsafe_name: str | None = None,
    symlink: bool = False,
) -> Path:
    staging = make_staging(fixture, platform, arch, version)
    archive = fixture / f"{ASSET_PREFIX}-{platform}-{arch}.tar.gz"
    with tarfile.open(archive, "w:gz") as handle:
        for path in sorted(staging.rglob("*")):
            handle.add(path, arcname=path.relative_to(staging), recursive=False)
        if unsafe_name:
            item = tarfile.TarInfo(unsafe_name)
            item.size = 0
            handle.addfile(item)
        if symlink:
            item = tarfile.TarInfo("plugins/z-codex-router/unsafe-link")
            item.type = tarfile.SYMTYPE
            item.linkname = "../../outside"
            handle.addfile(item)
    (fixture / "SHA256SUMS").write_text(f"{sha256(archive)}  {archive.name}\n")
    return archive


def environment(root: Path, fixture: Path, tools: Path) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(root / "home"),
            "CODEX_HOME": str(root / "codex-home"),
            "CODEX_BIN": str(tools / "codex"),
            "ZCR_FIXTURE_DIR": str(fixture),
            "ZCR_TEST_CODEX_LOG": str(root / "codex.log"),
            "ZCR_TEST_ROUTER_LOG": str(root / "router.log"),
            "PATH": f"{tools}{os.pathsep}{env.get('PATH', '')}",
        }
    )
    Path(env["HOME"]).mkdir(parents=True, exist_ok=True)
    return env


def run_installer(
    root: Path,
    fixture: Path,
    tools: Path,
    *arguments: str,
    check: bool = True,
    env_override: dict[str, str] | None = None,
    version: str = "1.0.0",
    codex_home: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    env = environment(root, fixture, tools)
    if env_override:
        env.update(env_override)
    explicit_codex_home = codex_home or Path(env["CODEX_HOME"])
    command = [
        "sh",
        str(INSTALLER),
        "--version",
        version,
        "--base-url",
        f"https://fixtures.example/v{version}",
        "--codex-home",
        str(explicit_codex_home),
        *arguments,
    ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"installer failed with {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def host_platform() -> tuple[str, str]:
    result = subprocess.run(
        [
            "sh",
            str(INSTALLER),
            "--resolve-platform",
            os.uname().sysname,
            os.uname().machine,
        ],
        text=True,
        capture_output=True,
        check=True,
    )
    platform, arch = result.stdout.strip().split("-", 1)
    return platform, arch


def require_failure(result: subprocess.CompletedProcess[str], marker: str) -> None:
    assert result.returncode != 0, result.stdout
    assert marker in result.stderr, result.stderr


def test_platform_mapping() -> None:
    fixtures = [
        ("Darwin", "arm64", "darwin-arm64"),
        ("Darwin", "x86_64", "darwin-amd64"),
        ("Linux", "aarch64", "linux-arm64"),
        ("Linux", "amd64", "linux-amd64"),
        ("Windows_NT", "ARM64", "windows-arm64"),
        ("Windows_NT", "X64", "windows-amd64"),
    ]
    for os_name, arch, expected in fixtures:
        result = subprocess.run(
            ["sh", str(INSTALLER), "--resolve-platform", os_name, arch],
            text=True,
            capture_output=True,
            check=True,
        )
        assert result.stdout.strip() == expected
    bad = subprocess.run(
        ["sh", str(INSTALLER), "--resolve-platform", "Plan9", "amd64"],
        text=True,
        capture_output=True,
    )
    require_failure(bad, "E_PLATFORM_UNSUPPORTED")


def test_synthetic_lifecycle() -> None:
    with tempfile.TemporaryDirectory(prefix="zcr-bootstrap-fixtures-") as temp:
        root = Path(temp)
        fixture = root / "release"
        fixture.mkdir()
        platform, arch = host_platform()
        archive = build_archive(fixture, platform=platform, arch=arch)
        tools = make_fake_tools(root)

        cold = run_installer(root, fixture, tools, "--enable")
        assert "ZCR_CACHE_HIT=false" in cold.stdout
        assert "ZCR_ENABLED=true" in cold.stdout
        expected_cold = archive.stat().st_size + (fixture / "SHA256SUMS").stat().st_size
        assert f"ZCR_DOWNLOADED_BYTES={expected_cold}" in cold.stdout

        hot = run_installer(root, fixture, tools, "--enable")
        assert "ZCR_CACHE_HIT=true" in hot.stdout
        assert "ZCR_SOURCE_REUSED=true" in hot.stdout
        assert (
            f"ZCR_DOWNLOADED_BYTES={(fixture / 'SHA256SUMS').stat().st_size}"
            in hot.stdout
        )

        cache = (
            root
            / "codex-home"
            / "z-codex-router-downloads"
            / f"z-codex-router-{platform}-{arch}.tar.gz"
        )
        cache.write_bytes(b"corrupt")
        repaired_cache = run_installer(root, fixture, tools, "--enable")
        assert "ZCR_CACHE_HIT=false" in repaired_cache.stdout
        assert sha256(cache) == sha256(archive)

        source = (
            root
            / "codex-home"
            / "z-codex-router-marketplaces"
            / f"{platform}-{arch}"
        )
        manifest = source / "plugins/z-codex-router/release/manifest.json"
        original = manifest.read_text()
        manifest.write_text(original + "tamper")
        repaired_source = run_installer(root, fixture, tools, "--enable")
        assert "ZCR_SOURCE_REUSED=false" in repaired_source.stdout
        assert "ZCR_PREVIOUS_SOURCE=" in repaired_source.stdout
        assert manifest.read_text() == original
        assert list(source.parent.glob(f".previous-{platform}-{arch}-*"))

        explicit_home = root / "explicit-codex-home"
        decoy_home = root / "decoy-codex-home"
        run_installer(
            root,
            fixture,
            tools,
            codex_home=explicit_home,
            env_override={"CODEX_HOME": str(decoy_home)},
        )
        explicit_log = (root / "codex.log").read_text()
        assert f"{explicit_home.resolve()}|plugin marketplace add" in explicit_log
        assert not decoy_home.exists()

        next_fixture = root / "release-1.0.1"
        next_fixture.mkdir()
        build_archive(
            next_fixture, platform=platform, arch=arch, version="1.0.1"
        )
        upgraded = run_installer(
            root, next_fixture, tools, "--enable", version="1.0.1"
        )
        assert "ZCR_VERSION=1.0.1" in upgraded.stdout
        assert f"ZCR_SOURCE={source.resolve()}" in upgraded.stdout
        version_root = (
            root
            / "codex-home"
            / "z-codex-router-marketplace-versions"
        )
        assert (version_root / "1.0.0" / f"{platform}-{arch}").is_dir()
        assert (version_root / "1.0.1" / f"{platform}-{arch}").is_dir()


def test_negative_paths() -> None:
    with tempfile.TemporaryDirectory(prefix="zcr-bootstrap-negative-") as temp:
        root = Path(temp)
        tools = make_fake_tools(root)
        platform, arch = host_platform()
        asset_name = f"z-codex-router-{platform}-{arch}.tar.gz"

        good = root / "good"
        good.mkdir()
        build_archive(good, platform=platform, arch=arch)
        no_codex = run_installer(
            root / "no-codex",
            good,
            tools,
            check=False,
            env_override={"CODEX_BIN": str(root / "missing-codex")},
        )
        require_failure(no_codex, "E_CODEX_MISSING")

        bad_checksum = root / "bad-checksum"
        bad_checksum.mkdir()
        archive = build_archive(bad_checksum, platform=platform, arch=arch)
        (bad_checksum / "SHA256SUMS").write_text(f"{'0' * 64}  {archive.name}\n")
        result = run_installer(root / "checksum-run", bad_checksum, tools, check=False)
        require_failure(result, "E_CHECKSUM_MISMATCH")

        missing_checksum = root / "missing-checksum"
        missing_checksum.mkdir()
        build_archive(missing_checksum, platform=platform, arch=arch)
        (missing_checksum / "SHA256SUMS").write_text(
            f"{'0' * 64}  another-file.tar.gz\n"
        )
        result = run_installer(
            root / "missing-checksum-run", missing_checksum, tools, check=False
        )
        require_failure(result, "E_CHECKSUM_ENTRY")

        missing_asset = root / "missing-asset"
        missing_asset.mkdir()
        (missing_asset / "SHA256SUMS").write_text(
            f"{'1' * 64}  {asset_name}\n"
        )
        result = run_installer(
            root / "missing-asset-run", missing_asset, tools, check=False
        )
        assert result.returncode != 0

        wrong_version = root / "wrong-version"
        wrong_version.mkdir()
        build_archive(
            wrong_version, platform=platform, arch=arch, version="9.9.9"
        )
        result = run_installer(
            root / "wrong-version-run", wrong_version, tools, check=False
        )
        require_failure(result, "E_RELEASE_VERSION")

        traversal = root / "traversal"
        traversal.mkdir()
        build_archive(
            traversal, platform=platform, arch=arch, unsafe_name="../escape"
        )
        result = run_installer(
            root / "traversal-run", traversal, tools, check=False
        )
        require_failure(result, "E_ARCHIVE_PATH")
        assert not (root / "traversal-run" / "escape").exists()

        link = root / "link"
        link.mkdir()
        build_archive(link, platform=platform, arch=arch, symlink=True)
        result = run_installer(root / "link-run", link, tools, check=False)
        require_failure(result, "E_ARCHIVE_TYPE")


def test_native_archive(
    archive: Path, platform: str, arch: str, real_codex: Path | None = None
) -> None:
    with tempfile.TemporaryDirectory(prefix="zcr-bootstrap-native-") as temp:
        root = Path(temp)
        fixture = root / "release"
        fixture.mkdir()
        copied = fixture / archive.name
        shutil.copy2(archive, copied)
        (fixture / "SHA256SUMS").write_text(f"{sha256(copied)}  {copied.name}\n")
        tools = make_fake_tools(root)
        detected_platform, detected_arch = host_platform()
        assert (detected_platform, detected_arch) == (platform, arch)
        override = {"CODEX_BIN": str(real_codex)} if real_codex else None
        cold = run_installer(
            root, fixture, tools, "--enable", env_override=override
        )
        assert '"code": "OK"' in cold.stdout
        assert "ZCR_CACHE_HIT=false" in cold.stdout
        hot = run_installer(
            root, fixture, tools, "--enable", env_override=override
        )
        assert '"code": "OK_NO_CHANGE"' in hot.stdout
        assert "ZCR_CACHE_HIT=true" in hot.stdout
        assert '"action": "doctor"' in hot.stdout
        if real_codex:
            env = environment(root, fixture, tools)
            env["CODEX_BIN"] = str(real_codex)
            listed = subprocess.run(
                [str(real_codex), "plugin", "list", "--json"],
                env=env,
                text=True,
                capture_output=True,
                check=True,
            )
            installed = json.loads(listed.stdout)["installed"]
            assert len(installed) == 1
            expected_source = (
                root
                / "codex-home"
                / "z-codex-router-marketplaces"
                / f"{platform}-{arch}"
            ).resolve()
            actual_source = Path(
                installed[0]["marketplaceSource"]["source"]
            ).resolve()
            assert actual_source == expected_source


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--platform", choices=["darwin", "linux"])
    parser.add_argument("--arch", choices=["amd64", "arm64"])
    parser.add_argument("--real-codex", type=Path)
    args = parser.parse_args()

    subprocess.run(["sh", "-n", str(INSTALLER)], check=True)
    test_platform_mapping()
    test_synthetic_lifecycle()
    test_negative_paths()
    if args.archive:
        if not args.platform or not args.arch:
            parser.error("--archive requires --platform and --arch")
        test_native_archive(
            args.archive, args.platform, args.arch, args.real_codex
        )
    print("POSIX bootstrap fixtures: OK")


if __name__ == "__main__":
    main()
