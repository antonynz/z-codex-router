[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Archive,
    [Parameter(Mandatory = $true)][ValidateSet("amd64", "arm64")][string]$Arch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

. (Join-Path (Split-Path -Parent $PSScriptRoot) "install.ps1")

function Assert-Contains {
    param([string]$Text, [string]$Expected)
    if (-not $Text.Contains($Expected)) {
        throw "expected output to contain: $Expected`n$Text"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Expected)
    try {
        & $Action
    }
    catch {
        if (-not $_.Exception.Message.Contains($Expected)) {
            throw
        }
        return
    }
    throw "expected failure containing: $Expected"
}

$mapping = @(
    @("Darwin", "arm64", "darwin-arm64"),
    @("Darwin", "x86_64", "darwin-amd64"),
    @("Linux", "aarch64", "linux-arm64"),
    @("Linux", "AMD64", "linux-amd64"),
    @("Windows_NT", "ARM64", "windows-arm64"),
    @("Windows_NT", "X64", "windows-amd64")
)
foreach ($fixture in $mapping) {
    $actual = Resolve-ZcrPlatform -Os $fixture[0] -Architecture $fixture[1]
    if ($actual -ne $fixture[2]) {
        throw "mapping mismatch: $($fixture -join ', ') => $actual"
    }
}
Assert-Throws { Resolve-ZcrPlatform -Os "Plan9" -Architecture "amd64" } `
    "E_PLATFORM_UNSUPPORTED"
Assert-Throws { Assert-SafeArchiveEntries -Entries @("../escape") } "E_ARCHIVE_PATH"
Assert-Throws { Assert-SafeArchiveEntries -Entries @("/absolute") } "E_ARCHIVE_PATH"
Assert-Throws {
    Assert-SafeArchiveEntries -Entries @("plugins/a", "plugins/a")
} "E_ARCHIVE_PATH"

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "zcr-powershell-fixtures-$PID-$([Guid]::NewGuid().ToString('N'))"
)
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $script:FixtureRoot = Join-Path $testRoot "release"
    New-Item -ItemType Directory -Path $script:FixtureRoot | Out-Null
    $assetName = "z-codex-router-windows-$Arch.tar.gz"
    $assetPath = Join-Path $script:FixtureRoot $assetName
    Copy-Item -LiteralPath $Archive -Destination $assetPath
    $assetHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $script:FixtureRoot "SHA256SUMS") `
        -Value "$assetHash  $assetName" -Encoding Ascii

    function Download-Https {
        param([string]$Url, [string]$Destination)
        if (-not $Url.StartsWith("https://")) {
            throw "E_URL_INSECURE"
        }
        $name = Split-Path -Leaf ([Uri]$Url).AbsolutePath
        $source = Join-Path $script:FixtureRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "E_DOWNLOAD: fixture asset is missing"
        }
        Copy-Item -LiteralPath $source -Destination $Destination
    }

    $fakeCodex = Join-Path $testRoot "codex.cmd"
    @"
@echo off
echo %*>>"$testRoot\codex.log"
echo {"ok":true}
exit /b 0
"@ | Set-Content -LiteralPath $fakeCodex -Encoding Ascii

    $codexHome = Join-Path $testRoot "codex-home"
    $arguments = @{
        Version = "1.0.0"
        BaseUrl = "https://fixtures.example/v1.0.0"
        CodexHome = $codexHome
        CodexBinary = $fakeCodex
        Enable = $true
    }
    $cold = (Invoke-ZcrInstall @arguments | Out-String)
    Assert-Contains $cold '"cacheHit": false'
    Assert-Contains $cold '"enabled": true'
    Assert-Contains $cold '"action": "doctor"'

    $hot = (Invoke-ZcrInstall @arguments | Out-String)
    Assert-Contains $hot '"cacheHit": true'
    Assert-Contains $hot '"sourceReused": true'
    Assert-Contains $hot '"code": "OK_NO_CHANGE"'
    Assert-Contains $hot '"action": "doctor"'

    $source = Join-Path $codexHome "z-codex-router-marketplaces/windows-$Arch"
    $manifest = Join-Path $source "plugins/z-codex-router/release/manifest.json"
    Add-Content -LiteralPath $manifest -Value "tamper"
    $repaired = (Invoke-ZcrInstall @arguments | Out-String)
    Assert-Contains $repaired '"sourceReused": false'
    Assert-Contains $repaired '"previousSource":'

    $negativeHome = Join-Path $testRoot "negative-home"
    Set-Content -LiteralPath (Join-Path $script:FixtureRoot "SHA256SUMS") `
        -Value "$(('0' * 64))  $assetName" -Encoding Ascii
    Assert-Throws {
        Invoke-ZcrInstall -Version "1.0.0" `
            -BaseUrl "https://fixtures.example/v1.0.0" `
            -CodexHome $negativeHome -CodexBinary $fakeCodex
    } "E_CHECKSUM_MISMATCH"

    Set-Content -LiteralPath (Join-Path $script:FixtureRoot "SHA256SUMS") `
        -Value "$assetHash  another-file.tar.gz" -Encoding Ascii
    Assert-Throws {
        Invoke-ZcrInstall -Version "1.0.0" `
            -BaseUrl "https://fixtures.example/v1.0.0" `
            -CodexHome (Join-Path $testRoot "missing-sum-home") `
            -CodexBinary $fakeCodex
    } "E_CHECKSUM_ENTRY"

    Set-Content -LiteralPath (Join-Path $script:FixtureRoot "SHA256SUMS") `
        -Value "$assetHash  $assetName" -Encoding Ascii
    Assert-Throws {
        Invoke-ZcrInstall -Version "1.0.1" `
            -BaseUrl "https://fixtures.example/v1.0.1" `
            -CodexHome (Join-Path $testRoot "wrong-version-home") `
            -CodexBinary $fakeCodex
    } "E_RELEASE_VERSION"

    Assert-Throws {
        Invoke-ZcrInstall -Version "1.0.0" `
            -BaseUrl "https://fixtures.example/v1.0.0" `
            -CodexHome (Join-Path $testRoot "no-codex-home") `
            -CodexBinary (Join-Path $testRoot "missing-codex.exe")
    } "E_CODEX_MISSING"

    Remove-Item -LiteralPath $assetPath
    Assert-Throws {
        Invoke-ZcrInstall -Version "1.0.0" `
            -BaseUrl "https://fixtures.example/v1.0.0" `
            -CodexHome (Join-Path $testRoot "missing-asset-home") `
            -CodexBinary $fakeCodex
    } "E_DOWNLOAD"

    Write-Output "PowerShell bootstrap fixtures: OK"
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
