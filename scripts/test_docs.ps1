$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Passed = 0

function Assert-Text {
    param([string]$Path, [string]$Expected)
    if (-not [IO.File]::Exists($Path)) { throw "FAIL: missing document: $Path" }
    $text = [IO.File]::ReadAllText($Path)
    if ($text.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) { throw "FAIL: missing '$Expected' in $Path" }
    $script:Passed++
}

Assert-Text ([IO.Path]::Combine($Root, "README.md")) "zcr-test:posix-install"
Assert-Text ([IO.Path]::Combine($Root, "README.md")) "zcr-test:powershell-install"
Assert-Text ([IO.Path]::Combine($Root, "README.md")) ': "${CODEX_HOME:=$HOME/.codex}"'
Assert-Text ([IO.Path]::Combine($Root, "README.md")) 'Join-Path $env:USERPROFILE ".codex"'
Assert-Text ([IO.Path]::Combine($Root, "README.md")) "zcr uninstall --purge-profile"
Assert-Text ([IO.Path]::Combine($Root, "README.en.md")) "Lifecycle contract"
Assert-Text ([IO.Path]::Combine($Root, "docs", "manual-install.md")) "SHA256SUMS"
Assert-Text ([IO.Path]::Combine($Root, "docs", "commands.md")) "retry_safe"
Assert-Text ([IO.Path]::Combine($Root, "docs", "troubleshooting.md")) "next_command"
Assert-Text ([IO.Path]::Combine($Root, "docs", "architecture.md")) "core/router.md"
Assert-Text ([IO.Path]::Combine($Root, "docs", "index.md")) "manual-install.md"

Write-Output "PASS test_docs.ps1 ($Passed assertions)"
