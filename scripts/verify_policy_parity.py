#!/usr/bin/env python3
"""Verify the portable router's explicit policy contracts and optional local parity."""
from __future__ import annotations

import argparse
import difflib
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins" / "z-codex-router"
MODES = [
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
]
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
CONTRACT_MARKERS = (
    "显式设置的 `CODEX_HOME` 优先",
    "禁止把仓库或 worktree 当作 Codex home",
    "只读取非空的 `model` 与 `reasoning_effort` 两个字段",
    "更高 effort 也不兼容",
    "runtime_observability=unobservable",
    "receipt protocol 1",
    "classification_owner=parent",
    "creation_tool=create_thread",
    "automatic_root_creations=1",
    "requested/accepted，不声称 actual verified",
    "C3/高风险",
    "纯提示协议没有密码学防伪能力",
    "子线程不得猜测",
    "不重新分类本任务",
    "自动根创建总数仍为 `<=1`",
    "在开始领域诊断前就创建精确的",
    "create_thread` 未直接暴露，先对线程创建能力执行一次 `tool_search`",
    "同一任务最多自动创建一次",
    "顺序任务不应创建 sub-agent",
    "方案固定后，必须重新分类具体实现 tier",
    "最终回报至少披露 `predicted_tier`",
    "新建独立根时，以新线程实际创建参数和运行时状态为准",
    "fork 只复制上下文，不复制人工授权",
    "safe-auto enable",
    "sandbox_mode = \"workspace-write\"",
    "approval_policy = \"on-request\"",
    "approvals_reviewer = \"auto_review\"",
    "路由 `uninstall` 不会自动恢复权限配置",
    "E_SAFE_AUTO_TRANSACTION_PENDING",
    "safe-auto doctor",
    "E_SAFE_AUTO_ACTIVE",
    "Persistent user profile override",
    "z-codex-router-profile.toml",
    "ROUTE_PROFILE_RUNTIME_UNAVAILABLE",
    "ROUTE_HANDOFF_REQUIRED",
    "ROUTE_CREATE_FAILED",
    "ROUTE_CREATE_UNAVAILABLE",
    "严禁 `spawn_agent` fallback",
    "final topology disclosure",
    "请为当前相同任务范围创建一个新的 Codex 独立任务",
    "Create a new independent Codex task for the same current scope",
    "profile restore <reset 返回的 backup 路径>",
)
PROFILE_OVERRIDE = {
    "user_path": "z-codex-router-profile.toml",
    "precedence": [
        "explicit-user-session-cli",
        "validated-user-override",
        "shipped-default",
    ],
    "invalid": "fail-closed",
    "runtime_allowlist": "create-thread-intersection-fail-closed",
    "restore": "managed-backup-only-validate-atomic",
}


def fail(message: str) -> None:
    raise SystemExit(f"policy parity failed: {message}")


def compare_local_modes(reference_root: Path) -> None:
    reference_router = reference_root / "router.md"
    if not reference_router.is_file():
        fail(f"reference router is missing: {reference_router}")
    for name in MODES:
        expected = reference_root / "modes" / name
        actual = PLUGIN / "core" / "modes" / name
        if not expected.is_file():
            fail(f"reference mode is missing: {expected}")
        if expected.read_bytes() != actual.read_bytes():
            diff = "".join(
                difflib.unified_diff(
                    expected.read_text().splitlines(keepends=True),
                    actual.read_text().splitlines(keepends=True),
                    fromfile=str(expected),
                    tofile=str(actual),
                )
            )
            fail(f"mode differs: {name}\n{diff[:4000]}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--reference-root",
        type=Path,
        help="optional external routing root containing router.md and modes/",
    )
    args = parser.parse_args()

    router = (PLUGIN / "core" / "router.md").read_text()
    missing = [marker for marker in CONTRACT_MARKERS if marker not in router]
    if missing:
        fail(f"missing core contract markers: {missing}")

    stable_path = PLUGIN / "profiles" / "stable" / "current-gpt-5.6-reference.toml"
    stable = tomllib.loads(stable_path.read_text())
    actual = {
        tier: (entry["model"], entry["effort"])
        for tier, entry in stable["routing"].items()
    }
    if actual != EXPECTED_ROUTING:
        fail(f"stable mapping differs: expected={EXPECTED_ROUTING} actual={actual}")
    mapping_markers = [
        f"| {tier} | {model} | {effort} |"
        for tier, (model, effort) in EXPECTED_ROUTING.items()
    ]
    missing_mapping = [marker for marker in mapping_markers if marker not in router]
    if missing_mapping:
        fail(f"core mapping table differs: {missing_mapping}")

    portable = tomllib.loads(
        (PLUGIN / "profiles" / "portable" / "default.toml").read_text()
    )
    preflight = portable["preflight"]
    if preflight.get("require_explicit_runtime_metadata") is not False or any(
        preflight.get(key) is not True
        for key in ("require_exact_route_match", "require_platform_capability")
    ) or preflight.get("runtime_observability") != "three-state":
        fail("portable preflight does not declare tri-state runtime observability")
    if preflight.get("on_unknown") != "receipt-aware" or any(
        preflight.get(key) != "fail-closed"
        for key in ("on_missing_profile", "on_incompatible_profile", "on_disabled_candidate")
    ):
        fail("portable profile does not fail closed for invalid policy inputs")
    receipt = portable.get("receipt", {})
    if receipt != {
        "protocol": 1,
        "classification_owner": "parent",
        "creation_tool": "create_thread",
        "max_automatic_root_creations": 1,
        "thread_id_source": "create_thread-return-only",
        "child_reclassification": "forbidden",
        "stage_reclassification": "parent-only-same-thread",
        "invalid_or_forged": "reject",
    }:
        fail("portable receipt policy differs")
    observability = portable.get("observability", {})
    if observability != {
        "states": ["observable", "unobservable"],
        "observable_exact": "verified",
        "observable_mismatch": "mismatch-fail-closed",
        "unobservable_non_c3": "requested-accepted-unverified",
        "unobservable_c3": "block-until-explicit-one-time-route-exception",
    }:
        fail("portable observability policy differs")
    if portable["selection"]["allow_candidate_as_default"] or portable["selection"]["silent_fallback"]:
        fail("portable selection permits candidate fallback")
    if portable.get("profile_override") != PROFILE_OVERRIDE:
        fail("portable profile override contract differs")

    for name in MODES:
        if not (PLUGIN / "core" / "modes" / name).is_file():
            fail(f"repository mode is missing: {name}")
    if args.reference_root:
        compare_local_modes(args.reference_root)
        print("Policy parity: internal contracts and reference modes OK")
    else:
        print("Policy parity: internal contracts OK")


if __name__ == "__main__":
    main()
