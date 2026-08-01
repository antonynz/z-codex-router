# Manual installation

Use the installer from a cloned checkout, an extracted release, or a verified
offline release directory. It always validates the source layout, rejects
compiled artifacts and unsafe archive entries, and registers the plugin before
an optional routing write.

## From a checkout or extracted archive

POSIX:

```sh
: "${CODEX_HOME:=$HOME/.codex}"
export CODEX_HOME
sh install.sh --source . --enable
export PATH="$CODEX_HOME/bin:$PATH"
zcr status
```

PowerShell 5.1 or 7:

```powershell
if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME = Join-Path $env:USERPROFILE ".codex" }
.\install.ps1 -Source . -Enable
& (Join-Path $env:CODEX_HOME "bin\zcr.ps1") status
```

If `CODEX_HOME` is not set, the default is `~/.codex` on POSIX and
`$env:USERPROFILE\.codex` on Windows. Pass `--codex-home PATH` or
`-CodexHome PATH` to use a different absolute home.

## From GitHub Release

Download the platform archive and `SHA256SUMS` from the same tag, verify the
matching entry exactly once, extract it, then invoke the included installer.
The complete copy-and-run examples are in the Chinese [README](../README.md#安装-release-归档).

The public version must match in all of these places: archive filename,
`SHA256SUMS`, release manifest, plugin manifest, installers, and controllers.
The packaging tests reject a mismatch rather than emitting a misleading asset.

## Offline/mirrored release

Place `SHA256SUMS` and the versioned asset in one directory. The offline mode
uses the same checksum and archive validation path as a network release:

```sh
sh install.sh --release-dir /srv/releases/zcr-1.1.0 --enable
```

```powershell
.\install.ps1 -ReleaseDirectory D:\releases\zcr-1.1.0 -Enable
```

## Stable entry points

Successful install writes a source pointer under
`$CODEX_HOME/z-codex-router-entrypoint/` and these immutable-name launchers:

| Platform | Entry point |
| --- | --- |
| POSIX | `$CODEX_HOME/bin/zcr` |
| PowerShell | `$CODEX_HOME/bin/zcr.ps1` |
| cmd.exe | `$CODEX_HOME/bin/zcr.cmd` |

The pointer is constrained to the installer-managed marketplace cache. An
unmanaged file at one of those names causes `E_ENTRYPOINT_CONFLICT`; it is not
overwritten.

## After installation

Use `zcr status` first. If `state=recovery-required`, run only the suggested
`zcr recover`; if it says `state=shadowed`, resolve the global override before
enabling. The command reference explains each state and code.
