#!/usr/bin/env python3
"""Verify the installed payload's active routing chain and safe-auto contract.

This verifier deliberately checks semantic anchors and hashes instead of requiring a
byte-for-byte copy of a reference document.  It has no third-party dependencies and
can inspect source trees, extracted release archives, or an actual routerctl fixture.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import tomllib
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PLUGIN = ROOT / "plugins" / "z-codex-router"
PAYLOAD_ROOTS = ("core", "profiles", "agents", "compatibility.json")
MODES = (
    "automation.md",
    "business-operations.md",
    "content.md",
    "design.md",
    "engineering.md",
    "general.md",
    "image.md",
    "product.md",
    "research.md",
    "testing.md",
    "video.md",
)
EXPECTED_ROUTING = {
    "A0": ("current-qualified-root", "runtime-qualified"),
    "A1": ("gpt-5.6-luna", "high"),
    "B0": ("gpt-5.6-luna", "xhigh"),
    "B1": ("gpt-5.6-terra", "high"),
    "B2": ("gpt-5.6-terra", "xhigh"),
    "C1": ("gpt-5.6-sol", "medium"),
    "C2": ("gpt-5.6-terra", "max"),
    "C3": ("gpt-5.6-sol", "max"),
}


def fail(message: str) -> None:
    raise SystemExit(f"policy activation failed: {message}")


def payload_hash(root: Path) -> str:
    files: list[Path] = []
    for relative in PAYLOAD_ROOTS:
        target = root / relative
        if target.is_file():
            files.append(target)
        elif target.is_dir():
            files.extend(path for path in target.rglob("*") if path.is_file())
    digest = hashlib.sha256()
    for path in sorted(files, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid JSON {path}: {error}")
    if not isinstance(value, dict):
        fail(f"JSON object required: {path}")
    return value


def verify_contract(plugin: Path) -> None:
    manifest = read_json(plugin / "release/manifest.json")
    if manifest.get("schemaVersion") != 1 or manifest.get("channel") != "stable":
        fail("release manifest is not a stable schema-1 manifest")
    if manifest.get("version") != "1.0.2":
        fail(f"unexpected active version: {manifest.get('version')!r}")
    actual_hash = payload_hash(plugin)
    if manifest.get("payloadSha256") != actual_hash:
        fail("release manifest payload hash does not match the package contents")
    compatibility = read_json(plugin / "compatibility.json")
    config_contract = compatibility.get("installer", {}).get("configToml")
    if config_contract != {
        "ordinaryInstallAndRoutingEnable": "untouched",
        "safeAutoApproval": "explicit-opt-in-three-keys",
    }:
        fail("compatibility metadata does not describe the explicit safe-auto config boundary")

    required = [
        "core/router.md",
        "core/classification.md",
        "core/policy.md",
        "profiles/schema.json",
        "profiles/portable/default.toml",
        "profiles/stable/current-gpt-5.6-reference.toml",
        "profiles/candidate/example-next-model.toml",
        "agents/README.md",
        *[f"core/modes/{name}" for name in MODES],
        *[f"agents/roles/{name}.toml" for name in ("analyst", "code_writer", "designer", "docs_writer", "media_creator", "reviewer", "runtime_validator")],
    ]
    missing = [relative for relative in required if not (plugin / relative).is_file()]
    if missing:
        fail(f"active payload is incomplete: {missing}")

    portable = tomllib.loads((plugin / "profiles/portable/default.toml").read_text())
    if portable.get("selection", {}).get("stable_profile") != "stable/current-gpt-5.6-reference.toml":
        fail("portable profile does not select the stable profile")
    preflight = portable.get("preflight", {})
    if any(preflight.get(key) is not True for key in (
        "require_explicit_runtime_metadata",
        "require_exact_route_match",
        "require_platform_capability",
    )):
        fail("portable preflight is not strict")
    if any(preflight.get(key) != "fail-closed" for key in (
        "on_unknown",
        "on_missing_profile",
        "on_incompatible_profile",
        "on_disabled_candidate",
    )):
        fail("portable profile does not fail closed")
    stable = tomllib.loads((plugin / "profiles/stable/current-gpt-5.6-reference.toml").read_text())
    actual_mapping = {
        tier: (entry.get("model"), entry.get("effort"))
        for tier, entry in stable.get("routing", {}).items()
    }
    if actual_mapping != EXPECTED_ROUTING:
        fail(f"stable tier mapping differs: {actual_mapping}")

    router = (plugin / "core/router.md").read_text()
    anchors = (
        "显式设置的 `CODEX_HOME` 优先",
        "禁止把仓库或 worktree 当作 Codex home",
        "current.json",
        "core/router.md",
        "profiles/portable/default.toml",
        "更高 effort 也不兼容",
        "unknown",
        "create_thread` 未直接暴露，先对线程创建能力执行一次 `tool_search`",
        "同一任务最多自动创建一次",
        "方案固定后，必须重新分类具体实现 tier",
        "独立根不是 sub-agent",
        "顺序任务不应创建 sub-agent",
        "发现最新 Git 分支",
        "新建独立根时，以新线程实际创建参数和运行时状态为准",
        "fork 只复制上下文，不复制人工授权",
        "safe-auto enable",
        "sandbox_mode = \"workspace-write\"",
        "approval_policy = \"on-request\"",
        "approvals_reviewer = \"auto_review\"",
        "不扩大 `workspace-write` sandbox",
        "Computer Use、凭证、支付、签署、发布、生产变更",
        "E_SAFE_AUTO_TRANSACTION_PENDING",
        "safe-auto doctor",
        "E_SAFE_AUTO_ACTIVE",
    )
    missing_anchors = [anchor for anchor in anchors if anchor not in router]
    if missing_anchors:
        fail(f"portable router contract is missing anchors: {missing_anchors}")

    engineering = (plugin / "core/modes/engineering.md").read_text()
    for marker in ("Web Frontend", "Flutter", "Android", "iOS", "HarmonyOS NEXT"):
        if marker not in engineering:
            fail(f"engineering mode lacks platform acceptance section: {marker}")


def verify_active_chain(codex_home: Path, plugin: Path | None = None) -> None:
    current_path = codex_home / "z-codex-router/current.json"
    current = read_json(current_path)
    version = current.get("version")
    payload_sha = current.get("payload_sha256")
    if not isinstance(version, str) or not isinstance(payload_sha, str):
        fail("current.json lacks version or payload_sha256")
    version_root = codex_home / "z-codex-router/versions" / version
    install = read_json(version_root / "install.json")
    if install.get("version") != version or install.get("payload_sha256") != payload_sha:
        fail("current.json, install.json, and version directory disagree")
    if payload_hash(version_root) != payload_sha:
        fail("installed version payload hash differs from current.json")
    for mode in MODES:
        if not (version_root / "core/modes" / mode).is_file():
            fail(f"active chain is missing mode entry: {mode}")
    stable = tomllib.loads((version_root / "profiles/stable/current-gpt-5.6-reference.toml").read_text())
    portable = tomllib.loads((version_root / "profiles/portable/default.toml").read_text())
    if portable["selection"]["stable_profile"] != "stable/current-gpt-5.6-reference.toml":
        fail("active portable profile does not select stable profile")
    if set(stable["routing"]) != set(EXPECTED_ROUTING):
        fail("active stable profile does not expose all eight tiers")
    for tier, expected in EXPECTED_ROUTING.items():
        entry = stable["routing"][tier]
        if (entry["model"], entry["effort"]) != expected:
            fail(f"active route mismatch for {tier}")
    router = (version_root / "core/router.md").read_text()
    if "core/router.md" not in router or "profiles/portable/default.toml" not in router:
        fail("active router chain is incomplete")
    if plugin is not None and version_root.resolve() == plugin.resolve():
        fail("active chain incorrectly points at the repository source")


def run_routerctl_fixture(plugin: Path, binary: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="zcr-policy-activation-") as temporary:
        home = Path(temporary) / "codex-home"
        home.mkdir()
        (home / "config.toml").write_text("unrelated = 1\n")

        def run(*arguments: str) -> dict:
            result = subprocess.run(
                [str(binary), "--source", str(plugin), "--codex-home", str(home), *arguments],
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode:
                fail(f"routerctl {' '.join(arguments)} failed: {result.stderr.strip()}")
            return json.loads(result.stdout)

        run("install")
        verify_active_chain(home, plugin)
        before = (home / "config.toml").read_text()
        if "sandbox_mode" in before:
            fail("routing install modified config.toml")
        enabled = run("safe-auto", "enable")
        if enabled.get("code") not in {"OK", "OK_NO_CHANGE"}:
            fail("safe-auto enable did not activate")
        config = tomllib.loads((home / "config.toml").read_text())
        expected = {
            "sandbox_mode": "workspace-write",
            "approval_policy": "on-request",
            "approvals_reviewer": "auto_review",
        }
        if {key: config.get(key) for key in expected} != expected:
            fail("safe-auto did not write the exact three-key policy")
        if run("safe-auto", "status").get("code") != "SAFE_AUTO_ACTIVE":
            fail("safe-auto status did not report active")
        with (home / "config.toml").open("a") as handle:
            handle.write("user_added = 2\n")
        run("safe-auto", "restore")
        restored = tomllib.loads((home / "config.toml").read_text())
        if restored != {"unrelated": 1, "user_added": 2}:
            fail("safe-auto restore did not preserve unrelated config")
        if run("safe-auto", "doctor").get("code") != "OK_ABSENT":
            fail("safe-auto doctor did not report absent")
        run("doctor")
        run("uninstall")
        run("doctor")

        # Exercise the same home resolution used by the managed AGENTS.md entry
        # without supplying --codex-home.  Each subprocess gets an isolated
        # environment; the repository checkout and the real user home are never
        # used as a target.
        repo_config = ROOT / "config.toml"
        repo_before = repo_config.read_bytes() if repo_config.exists() else None
        repo_agents = ROOT / "AGENTS.md"
        repo_agents_before = repo_agents.read_bytes() if repo_agents.exists() else None

        def run_no_flag(environment: dict[str, str], *arguments: str) -> dict:
            result = subprocess.run(
                [str(binary), "--source", str(plugin), *arguments],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode:
                fail(f"routerctl {' '.join(arguments)} home resolution failed: {result.stderr.strip()}")
            return json.loads(result.stdout)

        explicit = Path(temporary) / "env-explicit"
        explicit_fallback = Path(temporary) / "env-explicit-fallback"
        explicit_env = dict(os.environ)
        explicit_env["CODEX_HOME"] = str(explicit)
        explicit_env["HOME"] = str(explicit_fallback)
        run_no_flag(explicit_env, "install")
        if not (explicit / "AGENTS.md").is_file() or not (explicit / "z-codex-router/current.json").is_file():
            fail("explicit CODEX_HOME install did not create its AGENTS/current chain")
        run_no_flag(explicit_env, "safe-auto", "enable")
        if not (explicit / "config.toml").is_file() or (explicit_fallback / "config.toml").exists():
            fail("explicit CODEX_HOME was not the only target")
        if repo_before != (repo_config.read_bytes() if repo_config.exists() else None):
            fail("no-flag explicit-home fixture changed repository config.toml")
        if repo_agents_before != (repo_agents.read_bytes() if repo_agents.exists() else None):
            fail("no-flag explicit-home fixture changed repository AGENTS.md")
        run_no_flag(explicit_env, "safe-auto", "restore")
        run_no_flag(explicit_env, "uninstall")

        fallback_home = Path(temporary) / "env-home"
        fallback_expected = fallback_home / ".codex"
        fallback_env = dict(os.environ)
        fallback_env.pop("CODEX_HOME", None)
        fallback_env["HOME"] = str(fallback_home)
        run_no_flag(fallback_env, "install")
        if not (fallback_expected / "AGENTS.md").is_file() or not (fallback_expected / "z-codex-router/current.json").is_file():
            fail("HOME fallback install did not create HOME/.codex AGENTS/current chain")
        run_no_flag(fallback_env, "safe-auto", "enable")
        if not (fallback_expected / "config.toml").is_file():
            fail("platform did not honor the isolated HOME/.codex fallback")
        if repo_before != (repo_config.read_bytes() if repo_config.exists() else None):
            fail("no-flag HOME fallback fixture changed repository config.toml")
        if repo_agents_before != (repo_agents.read_bytes() if repo_agents.exists() else None):
            fail("no-flag HOME fallback fixture changed repository AGENTS.md")
        run_no_flag(fallback_env, "safe-auto", "restore")
        run_no_flag(fallback_env, "uninstall")

        # Safe-auto is independently opt-in and may be enabled before routing.  Simulate
        # an interruption after config.toml was written but before safe-auto state cleanup,
        # then require safe-auto doctor to validate recovery separately from route Doctor.
        recovery_home = Path(temporary) / "route-absent-recovery"
        recovery_home.mkdir()
        original = "unrelated = 1\n"
        (recovery_home / "config.toml").write_text(original)
        def run_with_home(home: Path, *arguments: str) -> dict:
            result = subprocess.run(
                [str(binary), "--source", str(plugin), "--codex-home", str(home), *arguments],
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode:
                fail(f"routerctl {' '.join(arguments)} recovery fixture failed: {result.stderr.strip()}")
            return json.loads(result.stdout)
        run_with_home(recovery_home, "safe-auto", "enable")
        state_path = recovery_home / "z-codex-router/safe-auto.json"
        journal_path = recovery_home / "z-codex-router/safe-auto.transaction.json"
        state = json.loads(state_path.read_text())
        active = (recovery_home / "config.toml").read_text()
        state_path.unlink()
        digest = lambda data: hashlib.sha256(b"present\0" + data.encode()).hexdigest()
        journal_path.write_text(json.dumps({
            "protocol": state["protocol"],
            "operation": "enable",
            "before_hash": digest(original),
            "after_hash": digest(active),
            "state": state,
        }))
        recovered = run_with_home(recovery_home, "recover")
        if recovered.get("code") != "OK_RECOVERED":
            fail("route-absent safe-auto recovery did not complete")
        if run_with_home(recovery_home, "safe-auto", "doctor").get("code") != "OK_ACTIVE":
            fail("route-absent safe-auto recovery did not produce OK_ACTIVE")
        routing_doctor = subprocess.run(
            [str(binary), "--source", str(plugin), "--codex-home", str(recovery_home), "doctor"],
            text=True,
            capture_output=True,
            check=False,
        )
        if routing_doctor.returncode == 0 or "E_SAFE_AUTO_ACTIVE" not in routing_doctor.stderr:
            fail("route-absent general doctor did not report E_SAFE_AUTO_ACTIVE boundary")


def verify_archive_payload(archive: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="zcr-policy-archive-") as temporary:
        destination = Path(temporary)
        with tarfile.open(archive, "r:gz") as handle:
            for member in handle.getmembers():
                pure = PurePosixPath(member.name)
                if pure.is_absolute() or ".." in pure.parts or "\\" in member.name:
                    fail(f"unsafe archive member: {member.name}")
                if not (member.isfile() or member.isdir()):
                    fail(f"archive contains a link or special file: {member.name}")
            handle.extractall(destination)
        verify_contract(destination / "plugins/z-codex-router")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_PLUGIN)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--routerctl", type=Path)
    args = parser.parse_args()
    if args.archive:
        verify_archive_payload(args.archive)
        print("Policy activation: archive chain OK")
        return
    plugin = args.source.resolve()
    verify_contract(plugin)
    with tempfile.TemporaryDirectory(prefix="zcr-policy-chain-") as temporary:
        home = Path(temporary) / "codex-home"
        version_root = home / "z-codex-router/versions/1.0.2"
        version_root.parent.mkdir(parents=True)
        shutil.copytree(plugin, version_root)
        state = {
            "version": "1.0.2",
            "payload_sha256": payload_hash(version_root),
            "installed_at_unix_ns": 0,
            "agents_existed_before": False,
            "managed_separator": "",
        }
        (version_root / "install.json").write_text(json.dumps(state))
        (home / "z-codex-router/current.json").write_text(json.dumps(state))
        verify_active_chain(home, plugin)
    if args.routerctl:
        run_routerctl_fixture(plugin, args.routerctl.resolve())
    print("Policy activation: source and active chain OK")


if __name__ == "__main__":
    main()
