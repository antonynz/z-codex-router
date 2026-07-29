---
name: router-doctor
description: Inspect a Z Codex Router installation without changing it. Use when the user asks to verify router installation, managed-block integrity, payload hashes, profiles, or runtime compatibility.
---

# Z Codex Router Doctor

Invoke `../../scripts/routerctl.sh doctor` on macOS/Linux or `../../scripts/routerctl.ps1 doctor` on Windows. This action is read-only. It checks the selected installation's state pointer, payload hash, managed `AGENTS.md` block, profile schema/files, disabled candidate status, and supported runtime platform.

Report the structured result as-is. A nonzero result is a verification failure, not permission to repair files manually; suggest the Enable or Upgrade skill only when its preflight can safely handle the reported stable error code.
