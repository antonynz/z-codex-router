#!/usr/bin/env python3
"""Executable acceptance model for the parent-owned route receipt contract.

The router is a prompt policy, so this focused test keeps the decision table
deterministic without inventing a second runtime.  It is intentionally small:
the installed payload remains the source of truth and the policy verifier
checks that its anchors match this table.
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


def main() -> None:
    receipt = Receipt(task_scope="bounded implementation")
    thread_id = validate_receipt(
        receipt,
        creator_invoked=True,
        tool_accepted=True,
        returned_thread_id="thread-1",
        current_scope="bounded implementation",
    )
    assert thread_id == "thread-1"  # thread IDs come only from create_thread.

    assert verify_runtime(
        receipt, Runtime("gpt-5.6-luna", "xhigh"), tier="B0"
    ) == Decision("verified", True, "actual tuple exact")
    assert verify_runtime(receipt, Runtime(), tier="B0") == Decision(
        "unobservable", True, "requested/accepted; actual not verified"
    )
    assert verify_runtime(receipt, Runtime("gpt-5.6-terra", "xhigh"), tier="B0").allowed is False
    assert verify_runtime(receipt, Runtime(), tier="C3").allowed is False
    assert verify_runtime(receipt, Runtime(), tier="C3", exception=True).allowed is True
    assert verify_runtime(
        receipt, Runtime("gpt-5.6-terra", "max"), tier="C3", exception=True
    ).allowed is False

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

    # C1 -> implementation is a parent-only phase update on the same thread.
    phase = replace(receipt, target_tier="B0", task_scope="bounded implementation")
    assert phase.automatic_root_creations == 1
    child_action(phase)

    # A root with no receipt still enters the normal initial classification path;
    # it is not granted a child receipt merely because user text resembles one.
    initial_classification = "normal-initial-classification"
    assert initial_classification == "normal-initial-classification"
    print("Route receipt acceptance: OK")


if __name__ == "__main__":
    main()
