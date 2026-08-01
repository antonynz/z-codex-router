[CmdletBinding()]
param([string]$Out = $(Join-Path ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))) "dist"))

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$Work = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zcr-package-" + [Guid]::NewGuid().ToString("N"))

function Get-ManifestVersion {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path, $Utf8NoBom)
    $match = [Regex]::Match($text, '(?m)^\s*"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)"')
    if (-not $match.Success) { throw "E_RELEASE_VERSION: manifest version is invalid: $Path" }
    return $match.Groups[1].Value
}

$Version = Get-ManifestVersion ([IO.Path]::Combine($Root, "plugins", "z-codex-router", "release", "manifest.json"))

try {
    $stage = [IO.Path]::Combine($Work, "z-codex-router-$Version")
    [void][IO.Directory]::CreateDirectory($stage)
    foreach ($entry in @(
        ".agents", ".gitattributes", ".github", ".gitignore", "AGENT_INSTALL.md",
        "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE", "README.md", "README.en.md", "RELEASE_NOTES.md",
        "SECURITY.md", "docs", "install.ps1", "install.sh", "zcr", "zcr.ps1", "zcr.cmd", "plugins", "scripts", "submission"
    )) {
        $source = [IO.Path]::Combine($Root, $entry)
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $stage -Recurse
        }
    }
    foreach ($junk in Get-ChildItem -LiteralPath $stage -Force -File -Recurse -Filter ".DS_Store") {
        [IO.File]::Delete($junk.FullName)
    }

    $releaseVersion = Get-ManifestVersion ([IO.Path]::Combine($stage, "plugins", "z-codex-router", "release", "manifest.json"))
    $pluginVersion = Get-ManifestVersion ([IO.Path]::Combine($stage, "plugins", "z-codex-router", ".codex-plugin", "plugin.json"))
    $installShText = [IO.File]::ReadAllText([IO.Path]::Combine($stage, "install.sh"), $Utf8NoBom)
    $installPsText = [IO.File]::ReadAllText([IO.Path]::Combine($stage, "install.ps1"), $Utf8NoBom)
    $routerShText = [IO.File]::ReadAllText([IO.Path]::Combine($stage, "plugins", "z-codex-router", "scripts", "routerctl.sh"), $Utf8NoBom)
    $routerPsText = [IO.File]::ReadAllText([IO.Path]::Combine($stage, "plugins", "z-codex-router", "scripts", "routerctl.ps1"), $Utf8NoBom)
    $escapedVersion = [Regex]::Escape($Version)
    $installShPattern = '(?m)^VERSION=' + $escapedVersion + '$'
    $installPsPattern = '(?m)^\s*\[string\]\$Version\s*=\s*"' + $escapedVersion + '"'
    $routerShPattern = '(?m)^PUBLIC_VERSION=' + $escapedVersion + '$'
    $routerPsPattern = '(?m)^\s*\$script:PublicVersion\s*=\s*"' + $escapedVersion + '"'
    if ($releaseVersion -ne $Version -or $pluginVersion -ne $Version -or
        $installShText -notmatch $installShPattern -or
        $installPsText -notmatch $installPsPattern -or
        $routerShText -notmatch $routerShPattern -or
        $routerPsText -notmatch $routerPsPattern) {
        throw "E_RELEASE_VERSION: package version drift (expected $Version)"
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
