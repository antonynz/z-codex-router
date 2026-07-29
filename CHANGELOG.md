# Changelog

## 1.0.2 - 2026-07-30

- Resolved the Codex home before reading router state in the managed `AGENTS.md` block, with
  explicit `CODEX_HOME` taking precedence over `~/.codex` and no repository-relative fallback.
- Expanded the portable routing core with exact model/effort matching for all persistent tiers,
  the C1 independent-root handoff, commentary and thread-creation protocol, post-C1
  reclassification, and sequential-task delegation boundaries.
- Added regression content contracts and synchronized active release metadata and asset checks.

## 1.0.1 - 2026-07-29

- Added `recover-router` and `uninstall-router` skills backed by fail-closed `recover` and
  `uninstall` control-plane commands.
- Added safe recovery for interrupted transactions, including verified cleanup of a version
  created by the interrupted transaction.
- Protected unmanaged `AGENTS.md` and `config.toml` content during uninstall, with repeatable
  not-enabled behavior and explicit Doctor status.
- Added bilingual README prompts for install and enable, recovery or rollback, and disable and
  uninstall workflows.

## 1.0.0 - 2026-07-29

- Renamed the unpublished local plugin, crate, marketplace, managed-state namespace, and release assets to Z Codex Router (`z-codex-router`).
- Initial local plugin scaffold and repository marketplace entry.
- Added fail-closed `routerctl` source, portable routing core, profiles, role templates, and fixture tests.
- Added explicit native Rust targets and packaged artifacts for macOS, Linux, and Windows on arm64 and x86_64.
- Added checksum-verified POSIX and PowerShell bootstrap installers with persistent marketplace
  sources, cache-aware repeat installs, explicit enablement, and isolated Doctor evidence.
- Added tag-gated public GitHub Release automation for six native archives, `SHA256SUMS`, bootstrap
  scripts, and the bilingual Agent install contract.
- Refocused the README and architecture diagrams on exact model and reasoning-effort selection.
- Added review-material templates. No public marketplace submission has been made.
