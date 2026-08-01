[CmdletBinding()]
param(
    [switch]$Enable,
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version = "1.1.0",
    [string]$BaseUrl,
    [string]$CodexHome = $env:CODEX_HOME,
    [string]$CodexBin = $env:CODEX_BIN,
    [string]$Source,
    [string]$ReleaseDirectory,
    [switch]$LegacyCleanupDryRun,
    [switch]$LegacyCleanup
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$Repository = "antonynz/z-codex-router"
$PluginName = "z-codex-router"
$MarketplaceName = "z-codex-router"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$WorkDir = $null
$DownloadedBytes = 0L

function Fail-Bootstrap {
    param([string]$Code, [string]$Message)
    $guidance = switch -Wildcard ($Code) {
        "E_ROUTER_*" { @("state=router-needs-attention", "impact=global-routing-not-enabled", "retry_safe=true", "next_command=zcr status"); break }
        "E_CHECKSUM_*" { @("state=release-verification-failed", "impact=package-not-installed", "retry_safe=true", "next_command=install.ps1 -ReleaseDirectory <verified-release-dir>"); break }
        "E_ARCHIVE_*" { @("state=release-verification-failed", "impact=package-not-installed", "retry_safe=true", "next_command=install.ps1 -ReleaseDirectory <verified-release-dir>"); break }
        "E_ENTRYPOINT_CONFLICT" { @("state=entrypoint-conflict", "impact=existing-command-preserved", "retry_safe=true", "next_command=install.ps1 -Source ."); break }
        default { @("state=failed", "impact=operation-not-completed", "retry_safe=true", "next_command=install.ps1 -Source .") }
    }
    $detail = @("$Code`: $Message", "code=$Code") + $guidance
    throw ($detail -join "`n")
}

function Get-Sha256File {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-CodexPluginCapability {
    param([string]$Candidate)
    try {
        & $Candidate plugin marketplace add --help *> $null
        if ($LASTEXITCODE -ne 0) { return $false }
        & $Candidate plugin add --help *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Resolve-CodexExecutable {
    param([string]$Explicit)

    if (-not [String]::IsNullOrWhiteSpace($Explicit)) {
        $command = Get-Command $Explicit -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            Fail-Bootstrap "E_CODEX_MISSING" "explicit Codex executable is not runnable: $Explicit"
        }
        $resolved = $command.Definition
        if (-not [IO.File]::Exists($resolved)) {
            Fail-Bootstrap "E_CODEX_MISSING" "explicit Codex executable is not a file: $Explicit"
        }
        if (-not (Test-CodexPluginCapability $resolved)) {
            Fail-Bootstrap "E_CODEX_CAPABILITY" "explicit Codex executable lacks plugin marketplace support"
        }
        return [PSCustomObject]@{ Path = $resolved; Source = "explicit" }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $pathCommand = Get-Command "codex" -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand) {
        $pathValue = $pathCommand.Definition
        $candidates.Add([PSCustomObject]@{ Path = $pathValue; Source = "path" })
    }
    if (-not [String]::IsNullOrEmpty($env:CODEX_CLI_PATH)) {
        $candidates.Add([PSCustomObject]@{ Path = $env:CODEX_CLI_PATH; Source = "desktop-runtime" })
    }
    if (-not [String]::IsNullOrEmpty($env:LOCALAPPDATA)) {
        foreach ($relative in @(
            "OpenAI\Codex\bin\codex.exe",
            "Programs\ChatGPT\resources\codex.exe",
            "Programs\Codex\resources\codex.exe"
        )) {
            $candidates.Add([PSCustomObject]@{
                Path = [IO.Path]::Combine($env:LOCALAPPDATA, $relative)
                Source = "desktop-app-local"
            })
        }
    }
    if (-not [String]::IsNullOrEmpty($env:USERPROFILE)) {
        $candidates.Add([PSCustomObject]@{
            Path = [IO.Path]::Combine($env:USERPROFILE, ".codex", "bin", "windows", "codex.exe")
            Source = "desktop-app-local"
        })
    }
    $getAppx = Get-Command "Get-AppxPackage" -ErrorAction SilentlyContinue
    if ($null -ne $getAppx) {
        foreach ($name in @("OpenAI.ChatGPT-Desktop", "OpenAI.Codex")) {
            foreach ($package in @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)) {
                if (-not [String]::IsNullOrEmpty($package.InstallLocation)) {
                    $candidates.Add([PSCustomObject]@{
                        Path = [IO.Path]::Combine($package.InstallLocation, "app", "resources", "codex.exe")
                        Source = "desktop-app-appx"
                    })
                }
            }
        }
    }

    $found = $false
    $seen = @{}
    foreach ($candidate in $candidates) {
        if ($seen.ContainsKey($candidate.Path)) { continue }
        $seen[$candidate.Path] = $true
        if (-not [IO.File]::Exists($candidate.Path)) { continue }
        $found = $true
        if (Test-CodexPluginCapability $candidate.Path) { return $candidate }
    }
    if ($found) {
        Fail-Bootstrap "E_CODEX_CAPABILITY" "Codex candidates were found but none support plugin marketplace commands; use -CodexBin"
    }
    Fail-Bootstrap "E_CODEX_MISSING" "Codex executable not found in PATH or supported desktop locations; install Codex CLI or use -CodexBin"
}

function Invoke-Download {
    param([string]$Url, [string]$Destination)
    if (-not $Url.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase)) {
        Fail-Bootstrap "E_URL_INSECURE" "only HTTPS URLs are accepted"
    }
    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -MaximumRedirection 5 -Uri $Url -OutFile $Destination
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
    }
}

function Get-ExpectedChecksum {
    param([string]$SumsPath, [string]$AssetName)
    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($SumsPath, $Utf8NoBom)) {
        $match = [Regex]::Match($line, '^([0-9a-fA-F]{64})\s+\*?(.+)$')
        if ($match.Success -and $match.Groups[2].Value -eq $AssetName) {
            $matches.Add($match.Groups[1].Value.ToLowerInvariant())
        }
    }
    if ($matches.Count -ne 1) {
        Fail-Bootstrap "E_CHECKSUM_ENTRY" "expected one checksum for $AssetName"
    }
    return $matches[0]
}

function Assert-NoCompiledFiles {
    param([string]$Root)
    foreach ($file in Get-ChildItem -LiteralPath $Root -Force -File -Recurse) {
        if ($file.Extension.ToLowerInvariant() -match '^\.(o|obj|a|lib|so|dylib|dll|exe|pdb|wasm|class|jar)$') {
            $relative = $file.FullName.Substring([IO.Path]::GetFullPath($Root).Length).TrimStart("\", "/")
            Fail-Bootstrap "E_COMPILED_ARTIFACT" "compiled artifact is forbidden: $relative"
        }
        $stream = [IO.File]::OpenRead($file.FullName)
        try {
            $magic = New-Object byte[] 4
            $count = $stream.Read($magic, 0, 4)
        }
        finally {
            $stream.Dispose()
        }
        if ($count -lt 2) { continue }
        $hex = ([BitConverter]::ToString($magic, 0, $count)).Replace("-", "").ToLowerInvariant()
        if ($hex.StartsWith("7f454c46") -or $hex.StartsWith("4d5a") -or
            $hex.StartsWith("feedface") -or $hex.StartsWith("feedfacf") -or
            $hex.StartsWith("cefaedfe") -or $hex.StartsWith("cffaedfe") -or
            $hex.StartsWith("cafebabe") -or $hex.StartsWith("bebafeca") -or
            $hex.StartsWith("cafebabf") -or $hex.StartsWith("bfbafeca") -or
            $hex.StartsWith("0061736d") -or $hex.StartsWith("213c6172") -or
            $hex.StartsWith("4243c0de") -or $hex.StartsWith("dec0170b")) {
            $relative = $file.FullName.Substring([IO.Path]::GetFullPath($Root).Length).TrimStart("\", "/")
            Fail-Bootstrap "E_COMPILED_ARTIFACT" "compiled executable is forbidden: $relative"
        }
    }
}

function Expand-SafeZip {
    param([string]$Archive, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [void][IO.Directory]::CreateDirectory($Destination)
    $destinationFull = [IO.Path]::GetFullPath($Destination).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ([String]::IsNullOrEmpty($name) -or [IO.Path]::IsPathRooted($name) -or
                $name.Contains("\") -or $name.Contains("`t") -or $name.Contains(" ") -or
                $name -notmatch '^[A-Za-z0-9._/+@-]+$') {
                Fail-Bootstrap "E_ARCHIVE_PATH" "unsafe archive entry: $name"
            }
            foreach ($segment in $name.Split('/')) {
                if ($segment -eq "..") {
                    Fail-Bootstrap "E_ARCHIVE_PATH" "path traversal entry: $name"
                }
            }
            if (-not $seen.Add($name)) {
                Fail-Bootstrap "E_ARCHIVE_PATH" "duplicate archive entry: $name"
            }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) {
                Fail-Bootstrap "E_ARCHIVE_TYPE" "symbolic links are forbidden: $name"
            }
            if ($unixType -ne 0 -and $unixType -ne 0x8000 -and $unixType -ne 0x4000) {
                Fail-Bootstrap "E_ARCHIVE_TYPE" "special files are forbidden: $name"
            }
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($Destination, $name.Replace([char]'/', [IO.Path]::DirectorySeparatorChar)))
            if (-not $target.StartsWith($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
                Fail-Bootstrap "E_ARCHIVE_PATH" "archive entry escapes extraction root: $name"
            }
            if ($name.EndsWith("/", [StringComparison]::Ordinal)) {
                [void][IO.Directory]::CreateDirectory($target)
                continue
            }
            $parent = [IO.Path]::GetDirectoryName($target)
            [void][IO.Directory]::CreateDirectory($parent)
            $input = $entry.Open()
            $output = [IO.File]::Create($target)
            try {
                $input.CopyTo($output)
            }
            finally {
                $input.Dispose()
                $output.Dispose()
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Find-PackageRoot {
    param([string]$Extracted)
    $direct = [IO.Path]::Combine($Extracted, "plugins", "z-codex-router", ".codex-plugin", "plugin.json")
    if ([IO.File]::Exists($direct)) { return $Extracted }
    $choices = New-Object System.Collections.Generic.List[string]
    foreach ($directory in Get-ChildItem -LiteralPath $Extracted -Force -Directory) {
        $manifest = [IO.Path]::Combine($directory.FullName, "plugins", "z-codex-router", ".codex-plugin", "plugin.json")
        if ([IO.File]::Exists($manifest)) { $choices.Add($directory.FullName) }
    }
    if ($choices.Count -ne 1) {
        Fail-Bootstrap "E_ARCHIVE_LAYOUT" "archive must contain exactly one package root"
    }
    return $choices[0]
}

function Get-ManifestVersion {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) {
        Fail-Bootstrap "E_SOURCE_INVALID" "source manifest is missing"
    }
    $text = [IO.File]::ReadAllText($Path, $Utf8NoBom)
    $match = [Regex]::Match($text, '(?m)^\s*"version"\s*:\s*"([^"]+)"')
    if (-not $match.Success -or $match.Groups[1].Value -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        Fail-Bootstrap "E_RELEASE_VERSION" "source manifest version is invalid"
    }
    return $match.Groups[1].Value
}

function Copy-MarketplaceSource {
    param([string]$PackageRoot, [string]$Destination)
    $marketplace = [IO.Path]::Combine($PackageRoot, ".agents", "plugins", "marketplace.json")
    $plugin = [IO.Path]::Combine($PackageRoot, "plugins", "z-codex-router")
    if (-not [IO.File]::Exists($marketplace) -or -not [IO.Directory]::Exists($plugin)) {
        Fail-Bootstrap "E_SOURCE_INVALID" "marketplace or plugin source is missing"
    }
    [void][IO.Directory]::CreateDirectory($Destination)
    Copy-Item -LiteralPath ([IO.Path]::Combine($PackageRoot, ".agents")) -Destination $Destination -Recurse
    Copy-Item -LiteralPath ([IO.Path]::Combine($PackageRoot, "plugins")) -Destination $Destination -Recurse
}

function Test-ManagedEntrypoint {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $false }
    if (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    return ([IO.File]::ReadAllText($Path, $Utf8NoBom).Contains("z-codex-router-entrypoint-v1"))
}

function Assert-EntrypointsAvailable {
    param([string]$PackageRoot, [string]$CodexHomePath)
    foreach ($name in @("zcr", "zcr.ps1", "zcr.cmd")) {
        $source = [IO.Path]::Combine($PackageRoot, $name)
        if (-not [IO.File]::Exists($source)) {
            Fail-Bootstrap "E_SOURCE_INVALID" "stable entry point is missing: $name"
        }
        $destination = [IO.Path]::Combine($CodexHomePath, "bin", $name)
        if (Test-Path -LiteralPath $destination) {
            if (-not (Test-ManagedEntrypoint $destination)) {
                Fail-Bootstrap "E_ENTRYPOINT_CONFLICT" "refusing to overwrite an unmanaged entry point: $destination"
            }
        }
    }
}

function Write-AtomicFile {
    param([string]$Source, [string]$Destination)
    $parent = [IO.Path]::GetDirectoryName($Destination)
    [void][IO.Directory]::CreateDirectory($parent)
    $temporary = [IO.Path]::Combine($parent, "." + [IO.Path]::GetFileName($Destination) + "." + [Guid]::NewGuid().ToString("N"))
    [IO.File]::WriteAllBytes($temporary, [IO.File]::ReadAllBytes($Source))
    try {
        if ([IO.File]::Exists($Destination)) {
            $backup = [IO.Path]::Combine($parent, "." + [Guid]::NewGuid().ToString("N") + ".replace")
            [IO.File]::Replace($temporary, $Destination, $backup, $true)
            if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        }
        else {
            [IO.File]::Move($temporary, $Destination)
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Write-AtomicText {
    param([string]$Destination, [string]$Text)
    $parent = [IO.Path]::GetDirectoryName($Destination)
    [void][IO.Directory]::CreateDirectory($parent)
    $temporary = [IO.Path]::Combine($parent, "." + [IO.Path]::GetFileName($Destination) + "." + [Guid]::NewGuid().ToString("N"))
    [IO.File]::WriteAllText($temporary, $Text, $Utf8NoBom)
    try {
        if ([IO.File]::Exists($Destination)) {
            $backup = [IO.Path]::Combine($parent, "." + [Guid]::NewGuid().ToString("N") + ".replace")
            [IO.File]::Replace($temporary, $Destination, $backup, $true)
            if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        }
        else {
            [IO.File]::Move($temporary, $Destination)
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Install-Entrypoints {
    param([string]$PackageRoot, [string]$CodexHomePath, [string]$CacheRoot)
    $entrypointDir = [IO.Path]::Combine($CodexHomePath, "bin")
    foreach ($name in @("zcr", "zcr.ps1", "zcr.cmd")) {
        Write-AtomicFile ([IO.Path]::Combine($PackageRoot, $name)) ([IO.Path]::Combine($entrypointDir, $name))
    }
    $pointer = [IO.Path]::Combine($CodexHomePath, "z-codex-router-entrypoint", "source")
    Write-AtomicText $pointer ([IO.Path]::Combine($CacheRoot, "plugins", "z-codex-router") + "`n")
}

function Set-CacheVersion {
    param([string]$Manifest, [string]$CacheVersion)
    $lines = [IO.File]::ReadAllLines($Manifest, $Utf8NoBom)
    $changed = $false
    for ($index = 0; $index -lt $lines.Length; $index++) {
        if (-not $changed -and $lines[$index] -match '^\s*"version"\s*:\s*"[^"]+"\s*,\s*$') {
            $lines[$index] = "  `"version`": `"$CacheVersion`","
            $changed = $true
        }
    }
    if (-not $changed) {
        Fail-Bootstrap "E_SOURCE_INVALID" "could not apply local cache build metadata"
    }
    [IO.File]::WriteAllText($Manifest, (($lines -join "`n") + "`n"), $Utf8NoBom)
}

function Invoke-Routerctl {
    param([string]$Launcher, [string[]]$Arguments)
    $engine = (Get-Process -Id $PID).Path
    $all = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Launcher, "--codex-home", $CodexHome) + $Arguments
    & $engine @all
    if ($LASTEXITCODE -ne 0) {
        Fail-Bootstrap "E_ROUTER_COMMAND" "routerctl failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Codex {
    param([string[]]$Arguments)
    $oldHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CodexHome
        & $CodexBin @Arguments
        if ($LASTEXITCODE -ne 0) {
            Fail-Bootstrap "E_CODEX_REGISTRATION" "Codex command failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        $env:CODEX_HOME = $oldHome
    }
}

function Get-RegisteredMarketplaceRoot {
    $oldHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CodexHome
        $lines = @(& $CodexBin plugin marketplace list --json)
        if ($LASTEXITCODE -ne 0) {
            Fail-Bootstrap "E_CODEX_REGISTRATION" "could not inspect configured marketplaces"
        }
        $text = $lines -join "`n"
        if ([String]::IsNullOrWhiteSpace($text)) { return $null }
        try {
            $document = $text | ConvertFrom-Json
        }
        catch {
            Fail-Bootstrap "E_CODEX_REGISTRATION" "marketplace list returned invalid JSON"
        }
        foreach ($marketplace in @($document.marketplaces)) {
            if ($marketplace.name -eq $MarketplaceName) { return [string]$marketplace.root }
        }
        return $null
    }
    finally {
        $env:CODEX_HOME = $oldHome
    }
}

$exitCode = 0
try {
    if ($LegacyCleanup -and $LegacyCleanupDryRun) {
        Fail-Bootstrap "E_USAGE" "choose one legacy cleanup mode"
    }
    if ([String]::IsNullOrEmpty($BaseUrl)) {
        $BaseUrl = "https://github.com/$Repository/releases/download/v$Version"
    }
    $BaseUrl = $BaseUrl.TrimEnd("/")
    if (-not $BaseUrl.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase)) {
        Fail-Bootstrap "E_URL_INSECURE" "--base-url must use HTTPS"
    }
    if ([String]::IsNullOrEmpty($CodexHome)) {
        if ([String]::IsNullOrEmpty($env:USERPROFILE)) {
            Fail-Bootstrap "E_CODEX_HOME_REQUIRED" "set CODEX_HOME or USERPROFILE"
        }
        $CodexHome = [IO.Path]::Combine($env:USERPROFILE, ".codex")
    }
    if (-not [IO.Path]::IsPathRooted($CodexHome)) {
        Fail-Bootstrap "E_CODEX_HOME_INVALID" "Codex home must be absolute"
    }
    $CodexHome = [IO.Path]::GetFullPath($CodexHome)
    $pathRoot = [IO.Path]::GetPathRoot($CodexHome)
    if ($CodexHome.TrimEnd("\", "/") -eq $pathRoot.TrimEnd("\", "/")) {
        Fail-Bootstrap "E_CODEX_HOME_INVALID" "filesystem root is unsafe"
    }
    if ([IO.Directory]::Exists($CodexHome) -and
        (((Get-Item -LiteralPath $CodexHome).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Fail-Bootstrap "E_CODEX_HOME_INVALID" "Codex home cannot be a symbolic link"
    }
    [void][IO.Directory]::CreateDirectory($CodexHome)
    $WorkDir = [IO.Path]::Combine($CodexHome, ".zcr-bootstrap-" + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($WorkDir)

    if (-not [String]::IsNullOrEmpty($Source) -and -not [String]::IsNullOrEmpty($ReleaseDirectory)) {
        Fail-Bootstrap "E_USAGE" "-Source and -ReleaseDirectory cannot be used together"
    }
    if (-not [String]::IsNullOrEmpty($Source)) {
        if (-not [IO.Directory]::Exists($Source)) {
            Fail-Bootstrap "E_SOURCE_INVALID" "local source path does not exist"
        }
        $packageRoot = [IO.Path]::GetFullPath($Source)
    }
    elseif (-not [String]::IsNullOrEmpty($ReleaseDirectory)) {
        if (-not [IO.Directory]::Exists($ReleaseDirectory)) {
            Fail-Bootstrap "E_RELEASE_DIRECTORY_INVALID" "release directory does not exist"
        }
        $releaseDirectoryFull = [IO.Path]::GetFullPath($ReleaseDirectory)
        $asset = "z-codex-router-$Version.zip"
        $sums = [IO.Path]::Combine($releaseDirectoryFull, "SHA256SUMS")
        $archive = [IO.Path]::Combine($releaseDirectoryFull, $asset)
        if (-not [IO.File]::Exists($sums)) { Fail-Bootstrap "E_CHECKSUM_ENTRY" "release directory is missing SHA256SUMS" }
        if (-not [IO.File]::Exists($archive)) { Fail-Bootstrap "E_ARCHIVE_INVALID" "release directory is missing $asset" }
        $expected = Get-ExpectedChecksum $sums $asset
        if ((Get-Sha256File $archive) -ne $expected) {
            Fail-Bootstrap "E_CHECKSUM_MISMATCH" $asset
        }
        $extracted = [IO.Path]::Combine($WorkDir, "extracted")
        Expand-SafeZip $archive $extracted
        $packageRoot = Find-PackageRoot $extracted
    }
    else {
        $asset = "z-codex-router-$Version.zip"
        $sums = [IO.Path]::Combine($WorkDir, "SHA256SUMS")
        $archive = [IO.Path]::Combine($WorkDir, $asset)
        Invoke-Download "$BaseUrl/SHA256SUMS" $sums
        $DownloadedBytes += (Get-Item -LiteralPath $sums).Length
        $expected = Get-ExpectedChecksum $sums $asset
        Invoke-Download "$BaseUrl/$asset" $archive
        $DownloadedBytes += (Get-Item -LiteralPath $archive).Length
        if ((Get-Sha256File $archive) -ne $expected) {
            Fail-Bootstrap "E_CHECKSUM_MISMATCH" $asset
        }
        $extracted = [IO.Path]::Combine($WorkDir, "extracted")
        Expand-SafeZip $archive $extracted
        $packageRoot = Find-PackageRoot $extracted
    }

    Assert-NoCompiledFiles $packageRoot
    foreach ($relative in @(
        ".agents/plugins/marketplace.json",
        "plugins/z-codex-router/.codex-plugin/plugin.json",
        "plugins/z-codex-router/release/manifest.json",
        "plugins/z-codex-router/core/router.md",
        "plugins/z-codex-router/scripts/routerctl.sh",
        "plugins/z-codex-router/scripts/routerctl.ps1",
        "zcr",
        "zcr.ps1",
        "zcr.cmd"
    )) {
        $required = [IO.Path]::Combine($packageRoot, $relative.Replace([char]'/', [IO.Path]::DirectorySeparatorChar))
        if (-not [IO.File]::Exists($required)) {
            Fail-Bootstrap "E_SOURCE_INVALID" "required source file is missing: $relative"
        }
    }
    $releaseManifest = [IO.Path]::Combine($packageRoot, "plugins", "z-codex-router", "release", "manifest.json")
    $pluginManifest = [IO.Path]::Combine($packageRoot, "plugins", "z-codex-router", ".codex-plugin", "plugin.json")
    $releaseVersion = Get-ManifestVersion $releaseManifest
    $pluginVersion = Get-ManifestVersion $pluginManifest
    if ($releaseVersion -ne $Version) {
        Fail-Bootstrap "E_RELEASE_VERSION" "requested $Version but source contains $releaseVersion"
    }
    if ($pluginVersion -ne $releaseVersion) {
        Fail-Bootstrap "E_RELEASE_VERSION" "plugin and release manifest versions differ"
    }
    $sourceLauncher = [IO.Path]::Combine($packageRoot, "plugins", "z-codex-router", "scripts", "routerctl.ps1")
    Assert-EntrypointsAvailable $packageRoot $CodexHome

    if ($LegacyCleanupDryRun) {
        Invoke-Routerctl $sourceLauncher @("--source", [IO.Path]::Combine($packageRoot, "plugins", "z-codex-router"), "legacy-cleanup", "--dry-run")
        return
    }
    if ($LegacyCleanup) {
        Invoke-Routerctl $sourceLauncher @("--source", [IO.Path]::Combine($packageRoot, "plugins", "z-codex-router"), "legacy-cleanup")
        return
    }

    $newFormat = [IO.Path]::Combine($CodexHome, "z-codex-router", "current", "format")
    try {
        if ([IO.File]::Exists($newFormat)) {
            $preflightAction = "upgrade"
            Invoke-Routerctl $sourceLauncher @("--source", [IO.Path]::Combine($packageRoot, "plugins", "z-codex-router"), "upgrade", "--dry-run")
        }
        else {
            $preflightAction = "install"
            Invoke-Routerctl $sourceLauncher @("--source", [IO.Path]::Combine($packageRoot, "plugins", "z-codex-router"), "dry-run")
        }
    }
    catch {
        [Console]::Error.WriteLine("NEXT_1=install.ps1 -LegacyCleanupDryRun")
        [Console]::Error.WriteLine("NEXT_2=install.ps1 -LegacyCleanup")
        [Console]::Error.WriteLine("NEXT_3=install.ps1 -Enable")
        throw
    }

    $codexResolution = Resolve-CodexExecutable $CodexBin
    $CodexBin = $codexResolution.Path
    $codexBinSource = $codexResolution.Source

    $cacheToken = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + $PID
    $cacheVersion = "$Version+codex.$cacheToken"
    $cacheParent = [IO.Path]::Combine($CodexHome, "z-codex-router-marketplaces")
    [void][IO.Directory]::CreateDirectory($cacheParent)
    $existingMarketplaceRoot = Get-RegisteredMarketplaceRoot
    $cacheReplaced = $false
    $cachePrevious = $null
    if (-not [String]::IsNullOrEmpty($existingMarketplaceRoot)) {
        $cacheRoot = [IO.Path]::GetFullPath($existingMarketplaceRoot)
        $managedPrefix = [IO.Path]::GetFullPath($cacheParent).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
        if (-not $cacheRoot.StartsWith($managedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Fail-Bootstrap "E_MARKETPLACE_CONFLICT" "existing z-codex-router marketplace is outside the managed cache"
        }
        if (-not [IO.Directory]::Exists($cacheRoot) -or
            (((Get-Item -LiteralPath $cacheRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Fail-Bootstrap "E_MARKETPLACE_CONFLICT" "existing managed marketplace root is invalid"
        }
        $cacheReplaced = $true
        $cachePrevious = [IO.Path]::Combine($cacheParent, ".previous-" + $cacheToken)
        if (Test-Path -LiteralPath $cachePrevious) {
            Fail-Bootstrap "E_CACHE_CONFLICT" "marketplace rollback path already exists"
        }
    }
    else {
        $cacheRoot = [IO.Path]::Combine($cacheParent, $cacheVersion)
        if (Test-Path -LiteralPath $cacheRoot) {
            Fail-Bootstrap "E_CACHE_CONFLICT" "local cache path already exists"
        }
    }
    $cacheStage = [IO.Path]::Combine($cacheParent, ".stage-" + $cacheToken)
    Copy-MarketplaceSource $packageRoot $cacheStage
    Set-CacheVersion ([IO.Path]::Combine($cacheStage, "plugins", "z-codex-router", ".codex-plugin", "plugin.json")) $cacheVersion
    if ($cacheReplaced) {
        [IO.Directory]::Move($cacheRoot, $cachePrevious)
    }
    [IO.Directory]::Move($cacheStage, $cacheRoot)
    $cacheLauncher = [IO.Path]::Combine($cacheRoot, "plugins", "z-codex-router", "scripts", "routerctl.ps1")

    try {
        Invoke-Codex @("plugin", "marketplace", "add", $cacheRoot, "--json")
        Invoke-Codex @("plugin", "add", "$PluginName@$MarketplaceName", "--json")
    }
    catch {
        $registrationFailure = $_.Exception.Message
        if ($cacheReplaced) {
            $failedCache = [IO.Path]::Combine($cacheParent, ".failed-" + $cacheToken)
            try {
                [IO.Directory]::Move($cacheRoot, $failedCache)
                [IO.Directory]::Move($cachePrevious, $cacheRoot)
                Invoke-Codex @("plugin", "add", "$PluginName@$MarketplaceName", "--json")
                [IO.Directory]::Delete($failedCache, $true)
            }
            catch {
                Fail-Bootstrap "E_CODEX_REGISTRATION_ROLLBACK" "registration failed and the previous plugin could not be restored"
            }
        }
        Fail-Bootstrap "E_CODEX_REGISTRATION" "registration failed; Router user files were not changed: $registrationFailure"
    }
    if ($cacheReplaced) {
        [IO.Directory]::Delete($cachePrevious, $true)
    }
    Install-Entrypoints $packageRoot $CodexHome $cacheRoot
    if ($Enable) {
        if ($preflightAction -eq "upgrade") {
            Invoke-Routerctl $cacheLauncher @("upgrade")
        }
        else {
            Invoke-Routerctl $cacheLauncher @("install")
        }
        try {
            Invoke-Routerctl $cacheLauncher @("doctor")
        }
        catch {
            $doctorFailure = $_.Exception.Message
            try {
                Invoke-Routerctl $cacheLauncher @("rollback")
            }
            catch {
                Fail-Bootstrap "E_ROUTER_ROLLBACK_REQUIRED" "Doctor failed after write and rollback did not complete; use the Recover Router skill"
            }
            Fail-Bootstrap "E_ROUTER_VALIDATION" "Doctor failed after write and Router state was rolled back: $doctorFailure"
        }
    }
    Write-Output "ZCR_VERSION=$Version"
    Write-Output "ZCR_CACHE_VERSION=$cacheVersion"
    Write-Output "ZCR_SOURCE=$cacheRoot"
    Write-Output "ZCR_DOWNLOADED_BYTES=$DownloadedBytes"
    Write-Output "ZCR_ROUTER_ACTION=$preflightAction"
    Write-Output ("ZCR_ENABLED=" + $Enable.IsPresent.ToString().ToLowerInvariant())
    Write-Output "ZCR_CODEX_BIN=$CodexBin"
    Write-Output "ZCR_CODEX_SOURCE=$codexBinSource"
    Write-Output "ZCR_ENTRYPOINT_POSIX=$([IO.Path]::Combine($CodexHome, "bin", "zcr"))"
    Write-Output "ZCR_ENTRYPOINT_POWERSHELL=$([IO.Path]::Combine($CodexHome, "bin", "zcr.ps1"))"
    Write-Output "ZCR_ENTRYPOINT_CMD=$([IO.Path]::Combine($CodexHome, "bin", "zcr.cmd"))"
    Write-Output ("ZCR_ROUTE_CREATE_AUTHORIZATION=" + $(if ($Enable) { "persistent-until-uninstall" } else { "inactive" }))
    Write-Output "ZCR_NEXT_COMMAND=zcr status"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $exitCode = 1
}
finally {
    if (-not [String]::IsNullOrEmpty($WorkDir) -and [IO.Directory]::Exists($WorkDir)) {
        try { [IO.Directory]::Delete($WorkDir, $true) } catch {}
    }
}
exit $exitCode
