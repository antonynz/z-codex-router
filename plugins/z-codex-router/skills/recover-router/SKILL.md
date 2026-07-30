---
name: recover-router
description: Safely recover an interrupted Z Codex Router install, enable, upgrade, uninstall, or safe-auto permission transaction without overwriting user changes. Use when the user asks to recover, repair, restore, retry after a failed router action, 恢复, 修复, 失败后重试, or reports E_TRANSACTION_PENDING or E_SAFE_AUTO_TRANSACTION_PENDING. Use rollback only when the user explicitly asks to undo a completed upgrade or enablement.
---

# Recover Z Codex Router

1. Run `doctor` with `../../scripts/routerctl.sh` on macOS/Linux or
   `../../scripts/routerctl.ps1` on Windows.
2. If it returns `E_TRANSACTION_PENDING` or `E_SAFE_AUTO_TRANSACTION_PENDING`, run `recover` once.
   This restores only the exact original transaction when the current files/config and journal match
   the expected before/after hashes. Safe-auto recovery also handles the interruption point after
   config restoration but before state/journal cleanup; it never rewrites unrelated `config.toml`
   content. It needs no second authorization because it is failure recovery, not a user rollback.
3. Complete the check for the transaction type you recovered:
   - after `E_TRANSACTION_PENDING`, run `doctor` again and report `OK_ENABLED` or
     `OK_NOT_ENABLED` exactly as returned;
   - after `E_SAFE_AUTO_TRANSACTION_PENDING`, run `safe-auto doctor` and require `OK_ACTIVE` or
     `OK_ABSENT`, then run the general `doctor` separately and report its routing result honestly.
     A route-absent installation with independently active safe-auto is expected to return
     `E_SAFE_AUTO_ACTIVE` from general `doctor`; that is an explicit opt-in boundary, not a failed
     safe-auto recovery.
4. If the user explicitly asks to undo a completed enablement or upgrade, run `rollback` only
   after Doctor is healthy. It replaces only the managed block and current pointer, preserving
   surrounding user-managed `AGENTS.md` content.

Stop on any other error, hash drift, or user-content conflict. Do not repair files manually or
silently invoke rollback.
