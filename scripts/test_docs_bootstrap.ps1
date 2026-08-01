$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$TestRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zcr-ps-docs-tests-" + [Guid]::NewGuid().ToString("N"))
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$Passed = 0
[void][IO.Directory]::CreateDirectory($TestRoot)

function Fail-Test { param([string]$Message) throw "FAIL: $Message" }
function Pass-Test { $script:Passed++ }
function Assert-Contains {
    param([string]$Text, [string]$Expected)
    if ($Text.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) { Fail-Test "missing '$Expected'" }
    Pass-Test
}
function Get-ReadmeBlock {
    param([string]$Marker)
    $lines = [IO.File]::ReadAllLines([IO.Path]::Combine($Root, "README.md"), $Utf8NoBom)
    $inside = $false
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line.Contains($Marker)) { $inside = $true; continue }
        if ($inside -and $line -eq '```') { break }
        if ($inside) { $result.Add($line) }
    }
    if ($result.Count -eq 0) { Fail-Test "README block is missing: $Marker" }
    return ($result -join "`n")
}

try {
    $readme = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "README.md"), $Utf8NoBom)
    Assert-Contains $readme "zcr-test:posix-install"
    Assert-Contains $readme "zcr-test:powershell-install"
    Assert-Contains $readme "README.en.md"
    Assert-Contains $readme "docs/commands.md"
    Assert-Contains $readme "docs/troubleshooting.md"

    $bin = [IO.Path]::Combine($TestRoot, "bin")
    [void][IO.Directory]::CreateDirectory($bin)
    Copy-Item -LiteralPath ([IO.Path]::Combine($Root, "scripts", "test_support", "fake-codex.cmd")) -Destination ([IO.Path]::Combine($bin, "codex.cmd"))
    $caseHome = [IO.Path]::Combine($TestRoot, "home")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $savedHome = $env:CODEX_HOME
    $savedPath = $env:PATH
    $savedLocation = (Get-Location).Path
    try {
        $env:CODEX_HOME = $caseHome
        $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
        Set-Location $Root
        $block = Get-ReadmeBlock "zcr-test:powershell-install"
        $output = (Invoke-Expression $block 2>&1 | Out-String)
    }
    finally {
        Set-Location $savedLocation
        $env:CODEX_HOME = $savedHome
        $env:PATH = $savedPath
    }
    Assert-Contains $output "code=OK_STATUS"
    Assert-Contains $output "state=enabled"

    $entrypoint = [IO.Path]::Combine($caseHome, "bin", "zcr.ps1")
    $savedHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $caseHome
        $output = (& $entrypoint disable 2>&1 | Out-String)
        $output += (& $entrypoint status 2>&1 | Out-String)
        $output += (& $entrypoint enable 2>&1 | Out-String)
        $output += (& $entrypoint profile set B2 gpt-5.6-terra high 2>&1 | Out-String)
    }
    finally {
        $env:CODEX_HOME = $savedHome
    }
    Assert-Contains $output "code=OK_DISABLED"
    Assert-Contains $output "code=OK_STATUS"
    Assert-Contains $output "state=disabled"
    Assert-Contains $output "code=OK_ENABLED"
    Assert-Contains $output "code=OK_PROFILE_SET"
    if (-not [IO.Directory]::Exists([IO.Path]::Combine($caseHome, "z-codex-router-marketplaces"))) {
        Fail-Test "disable removed the registered plugin cache"
    }
    Pass-Test

    Write-Output "PASS test_docs_bootstrap.ps1 ($Passed assertions)"
}
finally {
    if ([IO.Directory]::Exists($TestRoot)) { [IO.Directory]::Delete($TestRoot, $true) }
}
