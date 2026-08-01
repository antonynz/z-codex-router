# z-codex-router-entrypoint-v1
# Stable PowerShell entry point. The installer owns the source pointer; this
# script intentionally contains no routing policy and can be called from any cwd.
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Fail-ZcrEntrypoint {
    param([string]$Code, [string]$Message)
    [Console]::Error.WriteLine("$Code`: $Message")
    [Console]::Error.WriteLine("code=$Code")
    [Console]::Error.WriteLine("state=entrypoint-unavailable")
    [Console]::Error.WriteLine("impact=global-routing-not-modified")
    [Console]::Error.WriteLine("retry_safe=true")
    [Console]::Error.WriteLine("next_command=.\\install.ps1 -Enable")
    exit 1
}

try {
    if (-not [String]::IsNullOrEmpty($env:CODEX_HOME)) {
        $codexHome = $env:CODEX_HOME
    }
    elseif (-not [String]::IsNullOrEmpty($env:USERPROFILE)) {
        $codexHome = [IO.Path]::Combine($env:USERPROFILE, ".codex")
    }
    else {
        Fail-ZcrEntrypoint "E_CODEX_HOME_REQUIRED" "set CODEX_HOME or USERPROFILE"
    }
    if (-not [IO.Path]::IsPathRooted($codexHome)) {
        Fail-ZcrEntrypoint "E_CODEX_HOME_INVALID" "Codex home must be absolute"
    }
    $codexHome = [IO.Path]::GetFullPath($codexHome)
    if (-not [IO.Directory]::Exists($codexHome)) {
        Fail-ZcrEntrypoint "E_ZCR_SOURCE_UNAVAILABLE" "Codex home does not exist; run the installer first"
    }
    $pointer = [IO.Path]::Combine($codexHome, "z-codex-router-entrypoint", "source")
    if (-not [IO.File]::Exists($pointer) -or
        (((Get-Item -LiteralPath $pointer -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Fail-ZcrEntrypoint "E_ZCR_SOURCE_UNAVAILABLE" "stable source pointer is missing; run the installer again"
    }
    $lines = [IO.File]::ReadAllLines($pointer, (New-Object Text.UTF8Encoding($false)))
    if ($lines.Count -ne 1 -or [String]::IsNullOrWhiteSpace($lines[0])) {
        Fail-ZcrEntrypoint "E_ZCR_SOURCE_UNAVAILABLE" "stable source pointer is invalid"
    }
    $sourceRoot = [IO.Path]::GetFullPath($lines[0])
    $managedPrefix = [IO.Path]::Combine($codexHome, "z-codex-router-marketplaces").TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
    if (-not $sourceRoot.StartsWith($managedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Directory]::Exists($sourceRoot) -or
        (((Get-Item -LiteralPath $sourceRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Fail-ZcrEntrypoint "E_ZCR_SOURCE_UNAVAILABLE" "managed Router source is unavailable; run the installer again"
    }
    $launcher = [IO.Path]::Combine($sourceRoot, "scripts", "routerctl.ps1")
    if (-not [IO.File]::Exists($launcher) -or
        (((Get-Item -LiteralPath $launcher -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Fail-ZcrEntrypoint "E_ZCR_SOURCE_UNAVAILABLE" "managed PowerShell control plane is unavailable; run the installer again"
    }
    $engine = (Get-Process -Id $PID).Path
    & $engine -NoProfile -ExecutionPolicy Bypass -File $launcher --source $sourceRoot --codex-home $codexHome @Arguments
    exit $LASTEXITCODE
}
catch {
    Fail-ZcrEntrypoint "E_ZCR_SOURCE_UNAVAILABLE" $_.Exception.Message
}
