---
name: uninstall-router
description: Safely disable and uninstall Z Codex Router while preserving user-managed configuration. Use when the user asks to uninstall, remove, disable and remove, 停用并卸载, 卸载, 移除, or clean up Z Codex Router after installation.
---

# Uninstall Z Codex Router

Keep the plugin and its launcher available until routerctl has completed every control-plane check.
Do not delete `AGENTS.md`, `config.toml`, marketplace sources, or user content manually.

If `safe-auto` is active, run `safe-auto doctor` and then `safe-auto restore` first. Routing uninstall
refuses to guess whether the user still wants the three permission keys and never removes them implicitly.

1. Run `doctor` with `../../scripts/routerctl.sh` on macOS/Linux or
   `../../scripts/routerctl.ps1` on Windows. If it reports a conflict, drift, pending transaction,
   permission, path, or compatibility error, stop. Keep the plugin and control plane intact.
2. Run `uninstall`. It checks the active payload hash, removes only its exact managed
   `AGENTS.md` block and current state, verifies the remaining user content byte-for-byte, then
   removes only its managed payload, backups, and state. Repeating it is safe.
3. Run `doctor` again and require `OK_NOT_ENABLED`. This means no global router state remains;
   routerctl does not claim to inspect plugin-registration state.
4. Only after those checks succeed, remove the plugin with
   `codex plugin remove z-codex-router@z-codex-router --json`. Report its result.

If the final plugin removal fails, report it without deleting any more files. The router has already
been safely disabled and can be retried through the normal plugin command.
