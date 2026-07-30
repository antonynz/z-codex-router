# Changelog

## 1.0.2 - 2026-07-30

- Resolved the Codex home before reading router state in the managed `AGENTS.md` block, with
  explicit `CODEX_HOME` taking precedence over `~/.codex` and no repository-relative fallback.
- Expanded the portable routing core with exact model/effort matching for all persistent tiers,
  the C1 independent-root handoff, commentary and thread-creation protocol, post-C1
  reclassification, and sequential-task delegation boundaries.
- Added regression content contracts and synchronized active release metadata and asset checks.
- Added an explicit `safe-auto` opt-in that atomically manages only the three approval/sandbox keys,
  with key-level restore, drift detection, crash recovery, status/Doctor checks, and an uninstall
  boundary that requires restoring permission configuration first.
- Added an end-to-end policy activation verifier and wired it into source and release-asset preflight;
  compatibility metadata now distinguishes untouched ordinary routing from explicit safe-auto config.
- Added protocol-1 parent-owned route receipts, a one-root creation cap, child non-reclassification,
  create-thread-only IDs, and observable/mismatch/unobservable runtime verification. Non-C3 unknown
  fields are explicitly requested/accepted (never claimed verified); C3 unknown fields require one
  scoped route exception and visible mismatch remains fail closed.
- Added an explicit same-version `upgrade` refresh with a journaled version-directory backup so local
  1.0.2 payload iterations can update the active managed block without touching safe-auto/config.toml.

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
