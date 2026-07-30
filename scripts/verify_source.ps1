[CmdletBinding()]
param([switch]$History)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))

function Fail-Verify { param([string]$Message) throw "FAIL verify_source.ps1: $Message" }

foreach ($relative in @("Cargo.toml", "Cargo.lock", "src", "plugins/z-codex-router/bin")) {
    $path = [IO.Path]::Combine($Root, $relative.Replace([char]'/', [IO.Path]::DirectorySeparatorChar))
    if (Test-Path -LiteralPath $path) { Fail-Verify "forbidden Rust/binary path remains: $relative" }
}

$forbiddenSource = Get-ChildItem -LiteralPath $Root -Force -File -Recurse |
    Where-Object {
        -not $_.FullName.StartsWith([IO.Path]::Combine($Root, ".git") + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        ($_.Extension.ToLowerInvariant() -match '^\.(py|pyc|rs|o|obj|a|lib|so|dylib|dll|exe|pdb|wasm|class|jar)$')
    } |
    Select-Object -First 1
if ($forbiddenSource -ne $null) {
    Fail-Verify "forbidden Rust/Python file remains: $($forbiddenSource.FullName)"
}

function Get-Magic {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = New-Object byte[] 4
        $count = $stream.Read($bytes, 0, 4)
        return ([BitConverter]::ToString($bytes, 0, $count)).Replace("-", "").ToLowerInvariant()
    }
    finally { $stream.Dispose() }
}

function Test-CompiledMagic {
    param([string]$Magic)
    return $Magic.StartsWith("7f454c46") -or $Magic.StartsWith("4d5a") -or
        $Magic.StartsWith("feedface") -or $Magic.StartsWith("feedfacf") -or
        $Magic.StartsWith("cefaedfe") -or $Magic.StartsWith("cffaedfe") -or
        $Magic.StartsWith("cafebabe") -or $Magic.StartsWith("bebafeca") -or
        $Magic.StartsWith("cafebabf") -or $Magic.StartsWith("bfbafeca") -or
        $Magic.StartsWith("0061736d") -or $Magic.StartsWith("213c6172") -or
        $Magic.StartsWith("4243c0de") -or $Magic.StartsWith("dec0170b")
}

foreach ($file in Get-ChildItem -LiteralPath $Root -Force -File -Recurse) {
    if ($file.FullName.StartsWith([IO.Path]::Combine($Root, ".git") + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        continue
    }
    if (Test-CompiledMagic (Get-Magic $file.FullName)) {
        Fail-Verify "compiled executable in current tree: $($file.FullName)"
    }
}

foreach ($name in @("z-codex-router-architecture-zh.png", "z-codex-router-architecture-en.png")) {
    $path = [IO.Path]::Combine($Root, "docs", "images", $name)
    if (-not [IO.File]::Exists($path) -or (Get-Magic $path) -ne "89504e47") {
        Fail-Verify "required PNG is missing or invalid: $name"
    }
}

$activeRoot = [IO.Path]::Combine($Root, "plugins", "z-codex-router")
foreach ($file in Get-ChildItem -LiteralPath $activeRoot -Force -File -Recurse) {
    $text = [IO.File]::ReadAllText($file.FullName)
    foreach ($match in [Regex]::Matches($text, '(?i)safe-auto\s+(enable|disable|doctor|status|restore)')) {
        $lineStart = $text.LastIndexOf("`n", $match.Index)
        $lineEnd = $text.IndexOf("`n", $match.Index)
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
        if ($lineEnd -lt 0) { $lineEnd = $text.Length }
        $line = $text.Substring($lineStart, $lineEnd - $lineStart)
        if ($line -notmatch '(?i)legacy|removed') {
            Fail-Verify "removed safe-auto command remains in active plugin content"
        }
    }
}

if ($History) {
    # The POSIX verifier performs raw-byte history scanning. On Windows, require Git and
    # independently ensure no forbidden historical paths remain after the rewrite.
    $objects = & git -C $Root rev-list --objects --all
    if ($LASTEXITCODE -ne 0) { Fail-Verify "git history enumeration failed" }
    foreach ($line in $objects) {
        if ($line -match '\splugins/z-codex-router/bin/' -or
            $line -match '(?i)\s.*\.(o|obj|a|lib|so|dylib|dll|exe|pdb|wasm|class|jar)$') {
            Fail-Verify "forbidden compiled path is reachable in rewritten history: $line"
        }
    }
}

Write-Output "PASS verify_source.ps1 (history=$($History.IsPresent.ToString().ToLowerInvariant()), PNG retained)"
