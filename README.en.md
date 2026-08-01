# Z Codex Router

Z Codex Router is a pure-script, auditable, fail-closed global task-routing
policy for Codex. Version 1.1.0 adds stable `zcr` entry points, explicit
lifecycle commands, recoverable profile customization, and matched behavior
on POSIX plus Windows PowerShell 5.1 and 7.

[中文说明](README.md) · [Command reference](docs/commands.md) · [Manual install](docs/manual-install.md) · [Troubleshooting](docs/troubleshooting.md) · [Architecture](docs/architecture.md) · [Security](SECURITY.md) · [Routing policy](plugins/z-codex-router/core/router.md)

## First-screen commands

Run these from a cloned repository or from the root of an extracted v1.1.0
release. The installer registers the plugin and writes stable entry points to
`$CODEX_HOME/bin`. Only `--enable` / `-Enable` writes the managed AGENTS block.

### macOS / Linux

```sh
: "${CODEX_HOME:=$HOME/.codex}"
export CODEX_HOME
sh install.sh --source . --enable
export PATH="$CODEX_HOME/bin:$PATH"
zcr disable
zcr enable
zcr upgrade
zcr profile set B2 gpt-5.6-terra high
zcr uninstall
zcr uninstall --purge-profile
```

### Windows PowerShell 5.1 / 7

```powershell
if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME = Join-Path $env:USERPROFILE ".codex" }
.\install.ps1 -Source . -Enable
$zcr = Join-Path $env:CODEX_HOME "bin\zcr.ps1"
& $zcr status
& $zcr disable
& $zcr enable
& $zcr upgrade
& $zcr profile set B2 gpt-5.6-terra high
& $zcr uninstall
& $zcr uninstall --purge-profile
```

The Windows install also supplies `zcr.cmd` for `cmd.exe`. The PowerShell path
above and the POSIX PATH setup are stable from any working directory.

## Lifecycle contract

| Command | Effect |
| --- | --- |
| `install` | Installs a fresh script-v1 managed payload. |
| `enable` | Ensures the selected payload is active and writes the managed block. |
| `status` | Non-mutating state report, including recovery and shadowing guidance. |
| `disable` | Removes only the managed block/current state; plugin and profile remain. |
| `upgrade` | Validates then replaces the active payload; profile bytes remain untouched. |
| `uninstall` | Removes managed payload state while retaining the profile by default. |
| `uninstall --purge-profile` | Backs up, checksums, then removes the user profile. |

Common lifecycle and profile commands emit stable machine-readable fields:
`code`, `state`, `impact`, `retry_safe`, and exactly one `next_command`;
controlled failure paths provide the same diagnostic fields. Profile changes
never require manual TOML editing: use `zcr profile set TIER MODEL EFFORT`, then
inspect with `zcr profile show` or recover with `zcr profile backups` /
`zcr profile restore`.

## Release assets and offline verification

Each GitHub release has content-identical `.tar.gz` and `.zip` source assets
plus `SHA256SUMS`. The installers verify the selected archive before extracting
it. For an air-gapped or mirrored release directory containing the exact asset
and `SHA256SUMS`, use:

```sh
sh install.sh --release-dir /absolute/path/to/release --enable
```

```powershell
.\install.ps1 -ReleaseDirectory C:\path\to\release -Enable
```

See [manual-install.md](docs/manual-install.md) for full release download
examples and [troubleshooting.md](docs/troubleshooting.md) for recovery-safe
next steps.
