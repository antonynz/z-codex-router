---
name: recover-router
description: Safely recover an interrupted Z Codex Router install, enable, upgrade, or uninstall transaction without overwriting user changes. Use when the user asks to recover, repair, restore, retry after a failed router action, 恢复, 修复, 失败后重试, or reports a pending Z Codex Router transaction. Use rollback only when the user explicitly asks to undo a completed upgrade or enablement.
---

# Recover Z Codex Router

1. Run `doctor` with `../../scripts/routerctl.sh` on macOS/Linux or
   `../../scripts/routerctl.ps1` on Windows.
2. If it returns `E_TRANSACTION_PENDING`, run `recover` once. This restores only the exact
   original transaction when both the current files and journal match the expected before/after
   values; it needs no second authorization because it is failure recovery, not a user rollback.
3. Run `doctor` again. Report `OK_ENABLED` or `OK_NOT_ENABLED` exactly as returned.
4. If the user explicitly asks to undo a completed enablement or upgrade, run `rollback` only
   after Doctor is healthy. It replaces only the managed block and current pointer, preserving
   surrounding user-managed `AGENTS.md` content.

Stop on any other error, hash drift, or user-content conflict. Do not repair files manually or
silently invoke rollback.
