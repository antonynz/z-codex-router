[CmdletBinding()]
param([string]$Out = $(Join-Path ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))) "dist"))

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Version = "1.0.1"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$Work = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zcr-package-" + [Guid]::NewGuid().ToString("N"))

try {
    $stage = [IO.Path]::Combine($Work, "z-codex-router-$Version")
    [void][IO.Directory]::CreateDirectory($stage)
    foreach ($entry in @(
        ".agents", ".gitattributes", ".github", ".gitignore", "AGENT_INSTALL.md",
        "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE", "README.md", "RELEASE_NOTES.md",
        "SECURITY.md", "docs", "install.ps1", "install.sh", "plugins", "scripts", "submission"
    )) {
        $source = [IO.Path]::Combine($Root, $entry)
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $stage -Recurse
        }
    }
    foreach ($junk in Get-ChildItem -LiteralPath $stage -Force -File -Recurse -Filter ".DS_Store") {
        [IO.File]::Delete($junk.FullName)
    }

    $releaseText = [IO.File]::ReadAllText([IO.Path]::Combine($stage, "plugins", "z-codex-router", "release", "manifest.json"))
    $pluginText = [IO.File]::ReadAllText([IO.Path]::Combine($stage, "plugins", "z-codex-router", ".codex-plugin", "plugin.json"))
    if ($releaseText -notmatch '(?m)^\s*"version"\s*:\s*"1\.0\.1"' -or
        $pluginText -notmatch '(?m)^\s*"version"\s*:\s*"1\.0\.1"') {
        throw "E_RELEASE_VERSION: package manifests must both be 1.0.1"
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($Out))
    $tarAsset = [IO.Path]::Combine([IO.Path]::GetFullPath($Out), "z-codex-router-$Version.tar.gz")
    $zipAsset = [IO.Path]::Combine([IO.Path]::GetFullPath($Out), "z-codex-router-$Version.zip")
    $sums = [IO.Path]::Combine([IO.Path]::GetFullPath($Out), "SHA256SUMS")
    foreach ($path in @($tarAsset, $zipAsset, $sums)) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    & tar -czf $tarAsset -C $Work "z-codex-router-$Version"
    if ($LASTEXITCODE -ne 0) { throw "E_PACKAGE: tar failed" }
    & tar -a -cf $zipAsset -C $Work "z-codex-router-$Version"
    if ($LASTEXITCODE -ne 0) { throw "E_PACKAGE: zip creation failed" }
    $tarHash = (Get-FileHash -LiteralPath $tarAsset -Algorithm SHA256).Hash.ToLowerInvariant()
    $zipHash = (Get-FileHash -LiteralPath $zipAsset -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        $sums,
        "$tarHash  $([IO.Path]::GetFileName($tarAsset))`n$zipHash  $([IO.Path]::GetFileName($zipAsset))`n",
        $Utf8NoBom
    )
    Write-Output "ZCR_TAR=$tarAsset"
    Write-Output "ZCR_ZIP=$zipAsset"
    Write-Output "ZCR_SUMS=$sums"
}
finally {
    if ([IO.Directory]::Exists($Work)) { [IO.Directory]::Delete($Work, $true) }
}
