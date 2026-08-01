# Troubleshooting

Start with `zcr status`. It is read-only and reports one of the ordinary
actionable states below.

| State or code | Impact | Recommended command |
| --- | --- | --- |
| `state=disabled` | Global routing is inactive. | `zcr enable` |
| `state=recovery-required` / `E_TRANSACTION_*` | A lifecycle write may be incomplete. | `zcr recover` |
| `state=shadowed` / `E_GLOBAL_OVERRIDE_ACTIVE` | A global override masks the managed routing block. | `zcr disable` after reviewing the override. |
| `state=legacy-cleanup-required` / `E_LEGACY_*` | Old Rust/prebuilt state was detected. | `zcr legacy-cleanup --dry-run` |
| `state=profile-needs-attention` / `E_PROFILE_*` | Profile bytes were not changed. | `zcr profile show` |
| `state=review-required` / drift errors | A protected user file or payload no longer matches recorded bytes. | `zcr status` |
| `E_ENTRYPOINT_CONFLICT` | An unmanaged command was preserved. | Re-run the installer only after choosing a non-conflicting command path. |
| `E_CHECKSUM_MISMATCH` | The release package was not installed. | Reacquire the matching asset and `SHA256SUMS`. |

## Reading a failure

Every controlled failure has a stable `E_*` code, a `state`, an `impact`, a
boolean `retry_safe`, and exactly one `next_command`. If `retry_safe=false`, do
not retry the previous command: run the recommended command, capture its
output, then continue only after it reports a safe state.

## Windows notes

Use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`
only when a host policy requires explicit invocation. The installer and
`zcr.ps1` are written for Windows PowerShell 5.1 syntax and are also tested in
PowerShell 7. If a required Codex executable cannot be found, pass `-CodexBin`
with its absolute executable path.

## Preserve user files

Do not delete `$CODEX_HOME/z-codex-router/transaction` by hand. Do not manually
edit the managed AGENTS block while a lifecycle action is pending. Profile reset
and profile purge write managed backups with SHA-256 metadata before removal;
use `zcr profile backups` and `zcr profile restore` to recover one.
