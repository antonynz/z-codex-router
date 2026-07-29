---
name: upgrade-router
description: Safely discover, dry-run, and upgrade an existing Z Codex Router installation. Use only when the user explicitly asks to upgrade Z Codex Router or roll back a failed upgrade; do not use for ordinary task routing.
---

# Upgrade Z Codex Router

First state the target home, source release being discovered, current version, planned backup, and rollback boundary. Keep this interaction inside Codex; do not tell the user to operate a command line.

1. Run the internal launcher with `upgrade --dry-run`.
2. If discovery says a newer stable release is compatible, run `upgrade`. The control plane creates a backup and atomically switches the current version only after it verifies the payload and managed block.
3. If upgrade fails after a transaction begins, the control plane restores its just-created backup before returning the error. If it reports `E_TRANSACTION_PENDING`, use the Recover Router skill; it restores only an exact interrupted transaction. Use `rollback` only when the user explicitly asks to restore the latest completed state. Do not replace a stable profile with a candidate profile: candidates are disabled and unevaluated by design.
4. Run Doctor after a successful upgrade and require `OK_ENABLED`.
5. Stop on conflict, incompatible profile/runtime, permission, or path errors and report the stable code without modifying files manually.
