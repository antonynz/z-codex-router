# Marketplace review materials (template)

This is a draft for a future reviewer. It intentionally contains no authentication claims and must not be represented as a submitted or approved listing.

## Listing copy

**Name:** Z Codex Router

**Short description:** Enable a portable, fail-closed global routing policy for Codex.

**Long description:** Z Codex Router installs a versioned global task-routing policy through a one-click Codex skill. It dry-runs first, preserves user-owned configuration, validates profiles and hashes, keeps candidates disabled, and offers doctor, upgrade, rollback, and uninstall controls.

## Starter prompts

1. Enable Z Codex Router globally.
2. Check my Z Codex Router installation.
3. Safely upgrade Z Codex Router.

## Positive test cases

1. Fresh temporary Codex home: enable succeeds, creates a versioned payload and one managed block.
2. Existing `AGENTS.md`: enable retains all user lines and appends only the identified block.
3. Existing complex `config.toml` with an `[agents]` table: record its bytes, then enable, doctor, same-version re-enable, and uninstall; its bytes remain identical after every action.
4. Same-version re-enable: returns a no-change result with no file-content diff.
5. Newer stable fixture: upgrade creates a backup, swaps the current pointer, and rollback restores the prior state.

## Negative test cases

1. Edited managed block: doctor and upgrade stop with `E_MANAGED_BLOCK_DRIFT`.
2. Missing portable profile, enabled candidate, or missing required mode/role: preflight fails closed with `E_PROFILE_INCOMPATIBLE`.
3. Dangerous `CODEX_HOME` (path traversal, filesystem root, or the real user home): preflight fails closed with `E_PATH_INVALID` or `E_CODEX_HOME_DANGEROUS`.

## Draft release notes

Z Codex Router 1.0.0 introduces a skills-only local router plugin with a Rust control plane, portable policy core, reference and disabled-candidate profiles, seven parameterized role templates, an untouched-1.0.0 `config.toml` boundary, immutable version directories, transaction backup/rollback, and fixture coverage. This draft does not announce a marketplace listing or OpenAI review.

## Pre-submission checklist

- [ ] Confirm the release package includes the matching platform binary and a checksum manifest.
- [ ] Confirm source, plugin, skill, fixture, secret, and path scans pass in a clean checkout.
- [ ] Confirm privacy, terms, support, version, license, and publisher information are accurate.
- [ ] Confirm no credentials, authentication assertions, personal paths, or real configuration are included.
- [ ] Confirm a qualified publisher, not an agent, submits and accepts the marketplace terms.
- [ ] Confirm no listing copy claims OpenAI review, approval, endorsement, or publication before it happens.
