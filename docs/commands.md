# Command reference

Run `zcr` after adding `$CODEX_HOME/bin` to POSIX `PATH`, or call
`& "$env:CODEX_HOME\bin\zcr.ps1"` on PowerShell. Direct controller scripts
remain supported for automation but are not the stable user-facing entry point.

## Lifecycle

| Command | Success code/state | Notes |
| --- | --- | --- |
| `zcr install` | `OK_ENABLED` or `OK_NO_CHANGE` | Fresh script-v1 install only. |
| `zcr enable` | `OK_ENABLED` | Idempotently enables the active source. |
| `zcr status [--cwd PATH]` | `OK_STATUS` | Non-mutating, including disabled/shadowed/recovery states. |
| `zcr doctor [--cwd PATH]` | `OK_ENABLED` / `OK_NOT_ENABLED` | Validates instruction-budget visibility. |
| `zcr disable` | `OK_DISABLED` | Removes managed routing while preserving plugin/profile. |
| `zcr upgrade [--dry-run]` | `OK_ENABLED` / `OK_DRY_RUN` | Profile bytes are deliberately not changed. |
| `zcr recover` | `OK_RECOVERED` | Use only after the recommended recovery state. |
| `zcr rollback` | `OK_ROLLED_BACK` | Requires managed-state drift checks to pass. |
| `zcr uninstall [--purge-profile]` | `OK_UNINSTALLED` | Default preserves profile; purge makes a checksum-backed backup first. |

`legacy-cleanup` remains an explicit migration command. Use
`zcr legacy-cleanup --dry-run` before applying it.

## Profiles

| Command | Purpose |
| --- | --- |
| `zcr profile show` | Displays the effective mapping and a ready-to-copy tier command. |
| `zcr profile set TIER MODEL EFFORT` | Creates/updates the override atomically. |
| `zcr profile init` | Creates a full editable override from the current effective mapping. |
| `zcr profile validate` | Fails closed for invalid mapping bytes. |
| `zcr profile reset` | Backs up then removes the override. |
| `zcr profile backups` | Lists managed profile backups and one restore command. |
| `zcr profile restore BACKUP` | Restores a checked managed backup without overwriting an existing profile. |

`A0` remains fixed. All other tiers use an accepted model token and one of
`medium`, `high`, `xhigh`, or `max`. The command never requires you to manually
edit TOML.

## Output contract

The common-state lifecycle records (`install`, `enable`, `status`, `doctor`,
`disable`, `upgrade`, and `uninstall`) and profile records include `code`,
`action`, `state`, `impact`, `retry_safe`, `changed`, and one `next_command`.
Controlled failures write the stable `E_*` code plus the same
state/impact/retry/next-command guidance to stderr. Treat `retry_safe=false` as
a stop condition: run the stated recovery command instead of repeating the
failed lifecycle action.
