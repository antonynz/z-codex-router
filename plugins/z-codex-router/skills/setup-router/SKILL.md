---
name: setup-router
description: Enable Z Codex Router's global task-routing policy. Use only when the user explicitly asks to install and enable, enable, install, or turn on Z Codex Router globally; this is not a per-task routing skill.
---

# Enable Z Codex Router

Before writing, state the selected Codex home, that the action will read the plugin payload, `AGENTS.md`, and router state, and that it will add only hash-identified managed content. State that 1.0.0 does not read or modify `config.toml`. Do not ask the user to use a CLI.

1. Invoke `../../scripts/routerctl.sh dry-run` on macOS/Linux or `../../scripts/routerctl.ps1 dry-run` on Windows. Pass `--codex-home` only when `CODEX_HOME` is set; otherwise let the internal launcher resolve the standard Codex home.
2. Show the dry-run's planned target and writes. If it reports a conflict, permission error, profile/runtime incompatibility, or unsafe path, stop and report its stable error code. Do not retry around it or alter files manually.
3. On successful dry-run, invoke the same launcher with `install`. It completes automatically only when all preflights pass; a failed transaction restores its original state before returning.
4. Invoke `doctor` and require `OK_ENABLED`. If a new session is required to load the plugin, report “installed but not enabled” and the single next step: invoke this Enable skill.
5. Report the installed version, backup location, Doctor result, and any no-change result. Do not run this skill merely because a task needs routing; the managed global entry point applies after it has been enabled.
