$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Engine = (Get-Process -Id $PID).Path
$TestRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zcr-ps-release-tests-" + [Guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($TestRoot)

function Get-TreeHash {
    param([string]$RootPath)
    $rootFull = [IO.Path]::GetFullPath($RootPath).TrimEnd("\", "/")
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $rootFull -Force -File -Recurse) {
        $paths.Add($file.FullName.Substring($rootFull.Length + 1).Replace("\", "/"))
    }
    $ordered = $paths.ToArray()
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $builder = New-Object Text.StringBuilder
    foreach ($relative in $ordered) {
        $full = [IO.Path]::Combine($rootFull, $relative.Replace([char]'/', [IO.Path]::DirectorySeparatorChar))
        [void]$builder.Append((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant())
        [void]$builder.Append("  $relative`n")
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($builder.ToString())
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

try {
    $dist = [IO.Path]::Combine($TestRoot, "dist")
    & $Engine -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($PSScriptRoot, "package_release.ps1")) -Out $dist
    if ($LASTEXITCODE -ne 0) { throw "package_release.ps1 failed" }
    $tarAsset = [IO.Path]::Combine($dist, "z-codex-router-1.0.1.tar.gz")
    $zipAsset = [IO.Path]::Combine($dist, "z-codex-router-1.0.1.zip")
    if (-not [IO.File]::Exists($tarAsset) -or -not [IO.File]::Exists($zipAsset)) {
        throw "release assets are missing"
    }
    $tarRoot = [IO.Path]::Combine($TestRoot, "tar")
    $zipRoot = [IO.Path]::Combine($TestRoot, "zip")
    [void][IO.Directory]::CreateDirectory($tarRoot)
    [void][IO.Directory]::CreateDirectory($zipRoot)
    & tar -xzf $tarAsset -C $tarRoot
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed" }
    Expand-Archive -LiteralPath $zipAsset -DestinationPath $zipRoot
    $tarPackage = [IO.Path]::Combine($tarRoot, "z-codex-router-1.0.1")
    $zipPackage = [IO.Path]::Combine($zipRoot, "z-codex-router-1.0.1")
    if ((Get-TreeHash $tarPackage) -ne (Get-TreeHash $zipPackage)) {
        throw "tar/zip extracted content differs"
    }
    $caseHome = [IO.Path]::Combine($TestRoot, "home")
    & $Engine -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($tarPackage, "plugins", "z-codex-router", "scripts", "routerctl.ps1")) --source ([IO.Path]::Combine($tarPackage, "plugins", "z-codex-router")) --codex-home $caseHome dry-run
    if ($LASTEXITCODE -ne 0) { throw "extracted PowerShell smoke failed" }
    Write-Output "PASS test_release.ps1 (tar/zip content parity and extracted smoke)"
}
finally {
    if ([IO.Directory]::Exists($TestRoot)) { [IO.Directory]::Delete($TestRoot, $true) }
}
