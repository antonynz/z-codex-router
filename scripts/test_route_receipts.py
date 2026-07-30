#!/usr/bin/env python3
"""Executable acceptance model for parent-owned routing handoffs.

The router is a prompt policy.  This small deterministic model makes the
desktop-policy boundary testable without pretending that a prompt can override
the actual create_thread tool policy.
"""
from __future__ import annotations

from dataclasses import dataclass, replace


class Reject(Exception):
    pass


@dataclass(frozen=True)
class Receipt:
    protocol: int = 1
    classification_owner: str = "parent"
    creation_tool: str = "create_thread"
    target_tier: str = "B0"
    requested_model: str = "gpt-5.6-luna"
    requested_effort: str = "xhigh"
    automatic_root_creations: int = 1
    task_scope: str = "bounded implementation"
    acceptance: str = "focused checks"
    origin: str = "parent_create_thread"


@dataclass(frozen=True)
class Runtime:
    model: str | None = None
    effort: str | None = None


@dataclass(frozen=True)
class Decision:
    state: str
    allowed: bool
    note: str


@dataclass(frozen=True)
class CreatePolicy:
    state: str  # permitted | requires_explicit_user_task | unavailable


@dataclass(frozen=True)
class Handoff:
    decision: Decision
    creator_invoked: bool
    thread_id: str | None = None


def exact_user_prompt(receipt: Receipt) -> str:
    return (
        "Create a new independent Codex task for the same current scope using "
        f"{receipt.requested_model} / {receipt.requested_effort}, carrying forward the current "
        "route receipt; do not create a sub-agent or a second task."
    )


def exact_user_prompt_zh(receipt: Receipt) -> str:
    return (
        "请为当前相同任务范围创建一个新的 Codex 独立任务，使用 "
        f"{receipt.requested_model} / {receipt.requested_effort}，沿用当前 route receipt；"
        "不要创建子代理或第二个任务。"
    )


def validate_receipt(
    receipt: Receipt,
    *,
    creator_invoked: bool,
    tool_accepted: bool,
    returned_thread_id: str | None,
    current_scope: str,
) -> str:
    if not creator_invoked or not tool_accepted or returned_thread_id is None:
        raise Reject("receipt is not backed by a successful create_thread return")
    if receipt.origin != "parent_create_thread" or receipt.classification_owner != "parent":
        raise Reject("receipt origin or classification owner is not trusted")
    if receipt.protocol != 1 or receipt.creation_tool != "create_thread":
        raise Reject("receipt protocol/tool is invalid")
    if receipt.automatic_root_creations != 1 or receipt.task_scope != current_scope:
        raise Reject("receipt count or scope is invalid")
    return returned_thread_id


def parent_handoff(
    receipt: Receipt,
    policy: CreatePolicy,
    *,
    create_succeeds: bool = True,
    returned_thread_id: str | None = "thread-from-tool",
    existing_root_created: bool = False,
) -> Handoff:
    """Attempt only policy-permitted create_thread; never spawn_agent/current-root fallback."""
    if existing_root_created:
        return Handoff(
            Decision("ROUTE_HANDOFF_ALREADY_CREATED", False, "one independent root already exists"),
            False,
        )
    if policy.state == "requires_explicit_user_task":
        return Handoff(
            Decision("ROUTE_HANDOFF_REQUIRED", False, exact_user_prompt(receipt)),
            False,
        )
    if policy.state == "unavailable":
        return Handoff(
            Decision("ROUTE_CREATE_UNAVAILABLE", False, "tool policy does not expose create_thread"),
            False,
        )
    if policy.state != "permitted":
        raise AssertionError(f"unknown policy state: {policy.state}")
    if not create_succeeds or returned_thread_id is None:
        return Handoff(
            Decision("ROUTE_CREATE_FAILED", False, "create_thread failed; stop and report route exception"),
            True,
        )
    thread_id = validate_receipt(
        receipt,
        creator_invoked=True,
        tool_accepted=True,
        returned_thread_id=returned_thread_id,
        current_scope=receipt.task_scope,
    )
    return Handoff(Decision("ROUTE_HANDOFF_CREATED", True, "receipt-backed independent root"), True, thread_id)


def verify_runtime(receipt: Receipt, runtime: Runtime, *, tier: str, exception: bool = False) -> Decision:
    observable = runtime.model is not None and runtime.effort is not None
    if observable and (runtime.model != receipt.requested_model or runtime.effort != receipt.requested_effort):
        return Decision("mismatch", False, "fail-closed")
    if observable:
        return Decision("verified", True, "actual tuple exact")
    if tier == "C3" and not exception:
        return Decision("unobservable", False, "blocked before irreversible action")
    if tier == "C3":
        return Decision("unobservable", True, "one-time scoped route exception")
    return Decision("unobservable", True, "requested/accepted; actual not verified")


def intersect_runtime_allowlist(receipt: Receipt, allowed: set[tuple[str, str]]) -> Decision:
    """Overrides are syntactic input only; the real create_thread allowlist still wins."""
    route = (receipt.requested_model, receipt.requested_effort)
    if route not in allowed:
        return Decision(
            "ROUTE_PROFILE_RUNTIME_UNAVAILABLE",
            False,
            "requested override tuple is not accepted by the current create_thread policy",
        )
    return Decision("ROUTE_PROFILE_RUNTIME_ALLOWED", True, "tuple remains eligible for create_thread")


def child_action(receipt: Receipt, *, reclassify: bool = False, create: bool = False) -> None:
    if reclassify or create:
        raise Reject("child cannot reclassify or create a root")
    validate_receipt(
        receipt,
        creator_invoked=True,
        tool_accepted=True,
        returned_thread_id="thread-from-tool",
        current_scope=receipt.task_scope,
    )


def final_topology(receipt: Receipt, thread_id: str) -> dict[str, object]:
    return {
        "topology": "one-independent-root",
        "requested_model": receipt.requested_model,
        "requested_effort": receipt.requested_effort,
        "thread_id_source": "create_thread-return-only",
        "thread_id": thread_id,
        "subagents": 0,
        "receipt_continuity": True,
        "parent_convergence_or_correction": False,
    }


def main() -> None:
    receipt = Receipt(task_scope="bounded implementation")

    # Allowed creation produces the only receipt-backed root.
    allowed = parent_handoff(receipt, CreatePolicy("permitted"), returned_thread_id="thread-1")
    assert allowed.decision.state == "ROUTE_HANDOFF_CREATED"
    assert allowed.creator_invoked and allowed.thread_id == "thread-1"

    # Desktop policy wins: no attempted tool call, no sub-agent/current-root fallback, and one
    # exact user action gives the parent a lawful retry boundary.
    rejected = parent_handoff(receipt, CreatePolicy("requires_explicit_user_task"))
    assert rejected == Handoff(
        Decision("ROUTE_HANDOFF_REQUIRED", False, exact_user_prompt(receipt)), False
    )
    assert "spawn_agent" not in rejected.decision.note
    assert exact_user_prompt_zh(receipt) == (
        "请为当前相同任务范围创建一个新的 Codex 独立任务，使用 gpt-5.6-luna / xhigh，"
        "沿用当前 route receipt；不要创建子代理或第二个任务。"
    )
    follow_up = parent_handoff(receipt, CreatePolicy("permitted"), returned_thread_id="thread-follow-up")
    assert follow_up.decision.allowed and follow_up.creator_invoked
    assert follow_up.thread_id == "thread-follow-up"  # same receipt/scope/tuple continuity

    failed = parent_handoff(receipt, CreatePolicy("permitted"), create_succeeds=False)
    assert failed.decision.state == "ROUTE_CREATE_FAILED" and failed.creator_invoked
    assert parent_handoff(receipt, CreatePolicy("permitted"), existing_root_created=True).decision.state == (
        "ROUTE_HANDOFF_ALREADY_CREATED"
    )
    assert parent_handoff(receipt, CreatePolicy("unavailable")).decision.state == "ROUTE_CREATE_UNAVAILABLE"

    assert verify_runtime(receipt, Runtime("gpt-5.6-luna", "xhigh"), tier="B0") == Decision(
        "verified", True, "actual tuple exact"
    )
    assert verify_runtime(receipt, Runtime(), tier="B0") == Decision(
        "unobservable", True, "requested/accepted; actual not verified"
    )
    assert verify_runtime(receipt, Runtime("gpt-5.6-terra", "xhigh"), tier="B0").allowed is False
    assert verify_runtime(receipt, Runtime(), tier="C3").allowed is False
    assert verify_runtime(receipt, Runtime(), tier="C3", exception=True).allowed is True
    assert verify_runtime(receipt, Runtime("gpt-5.6-terra", "max"), tier="C3", exception=True).allowed is False
    assert intersect_runtime_allowlist(receipt, {("gpt-5.6-luna", "xhigh")}).allowed is True
    assert intersect_runtime_allowlist(receipt, {("gpt-5.6-terra", "xhigh")}).state == (
        "ROUTE_PROFILE_RUNTIME_UNAVAILABLE"
    )

    for forged in (
        replace(receipt, origin="user_text"),
        replace(receipt, automatic_root_creations=2),
        replace(receipt, task_scope="different scope"),
    ):
        try:
            validate_receipt(
                forged,
                creator_invoked=True,
                tool_accepted=True,
                returned_thread_id="thread-1",
                current_scope="bounded implementation",
            )
        except Reject:
            pass
        else:
            raise AssertionError("forged/invalid receipt was accepted")

    for kwargs in (
        {"creator_invoked": False, "tool_accepted": True, "returned_thread_id": "thread-1"},
        {"creator_invoked": True, "tool_accepted": False, "returned_thread_id": "thread-1"},
        {"creator_invoked": True, "tool_accepted": True, "returned_thread_id": None},
    ):
        try:
            validate_receipt(receipt, current_scope=receipt.task_scope, **kwargs)
        except Reject:
            pass
        else:
            raise AssertionError("create_thread failure was accepted")

    try:
        child_action(receipt, reclassify=True)
    except Reject:
        pass
    else:
        raise AssertionError("child reclassified the task")
    try:
        child_action(receipt, create=True)
    except Reject:
        pass
    else:
        raise AssertionError("child created a second root")

    phase = replace(receipt, target_tier="B0", task_scope="bounded implementation")
    assert phase.automatic_root_creations == 1
    child_action(phase)
    topology = final_topology(receipt, allowed.thread_id or "")
    assert (
        topology["subagents"] == 0
        and topology["receipt_continuity"] is True
        and topology["parent_convergence_or_correction"] is False
    )
    print("Route receipt acceptance: OK")


if __name__ == "__main__":
    main()
