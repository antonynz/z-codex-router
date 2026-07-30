---
name: setup-router
description: Enable Z Codex Router's global task-routing policy or handle an explicitly requested safe-auto approval opt-in. Use only when the user explicitly asks to install and enable, enable, install, or turn on Z Codex Router globally, or asks to safe-auto enable, safe-auto restore, safe-auto status, safe-auto doctor, or turn safe automatic approval on/off/check; ordinary routing enable never implies safe-auto.
---

# Enable Z Codex Router

Before writing, state the selected Codex home, that the action will read the plugin payload, `AGENTS.md`, and router state, and that it will add only hash-identified managed content. State that routing install/enable does not read or modify `config.toml`; safe automatic approval is a separate explicit opt-in and is never implied. Do not ask the user to use a CLI.

1. Invoke `../../scripts/routerctl.sh dry-run` on macOS/Linux or `../../scripts/routerctl.ps1 dry-run` on Windows. Pass `--codex-home` only when `CODEX_HOME` is set; otherwise let the internal launcher resolve the standard Codex home.
2. Show the dry-run's planned target and writes. If it reports a conflict, permission error, profile/runtime incompatibility, or unsafe path, stop and report its stable error code. Do not retry around it or alter files manually.
3. On successful dry-run, invoke the same launcher with `install`. It completes automatically only when all preflights pass; a failed transaction restores its original state before returning.
4. Invoke `doctor` and require `OK_ENABLED`. If a new session is required to load the plugin, report “installed but not enabled” and the single next step: invoke this Enable skill.
5. Report the installed version, backup location, Doctor result, and any no-change result. Do not run this skill merely because a task needs routing; the managed global entry point applies after it has been enabled.

## Safe automatic approval is separate

Only when the user explicitly opts in, invoke the packaged launcher with `safe-auto enable`. It
atomically manages exactly `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`, and
`approvals_reviewer = "auto_review"`. Run `safe-auto doctor` or `safe-auto status` afterward. Auto-review
does not expand the sandbox or replace human authorization for Computer Use, credentials, or external
high-risk/irreversible actions. On disablement, run `safe-auto restore` (or `safe-auto disable`) before
router uninstall; it restores only the three backed-up keys and stops on drift.
