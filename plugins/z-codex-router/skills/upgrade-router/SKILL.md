---
name: upgrade-router
description: Safely discover, dry-run, and upgrade an existing Z Codex Router installation. Use only when the user explicitly asks to upgrade Z Codex Router or roll back a failed upgrade; do not use for ordinary task routing.
---

# Upgrade Z Codex Router

First state the target home, source release being discovered, current version, planned backup, and rollback boundary. Keep this interaction inside Codex; do not tell the user to operate a command line.

1. Run the **latest installed launcher's** `upgrade --dry-run`; do not uninstall first and do not invoke an old version's launcher.
2. A healthy 1.0.1 legacy profile/managed block or 1.0.2 contract is validated against its installed version's own exact payload evidence, then replaced transactionally by the new managed block/current pointer. The upgrade preserves user `AGENTS.md`, `config.toml`, Safe Auto state, and `z-codex-router-profile.toml` byte-for-byte.
3. If discovery says a newer stable release is compatible, run `upgrade`. A genuine changed legacy block stays `E_MANAGED_BLOCK_DRIFT`; a malformed recognized legacy profile stays `E_LEGACY_PROFILE_INCOMPATIBLE`; neither is permission to overwrite or uninstall-first.
4. If upgrade fails after a transaction begins, the control plane restores its just-created backup before returning the error. If it reports `E_TRANSACTION_PENDING`, use the Recover Router skill; it restores only an exact interrupted transaction. Use `rollback` only when the user explicitly asks to restore the latest completed state. Do not replace a stable profile with a candidate profile: candidates are disabled and unevaluated by design.
5. Run Doctor after a successful upgrade and require `OK_ENABLED`.
6. Stop on conflict, incompatible profile/runtime, permission, or path errors and report the stable code without modifying files manually. Existing tasks retain loaded plugin context; ask the user to start a new task to pick up updated skills/tools.
