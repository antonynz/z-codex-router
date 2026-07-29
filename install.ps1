[CmdletBinding()]
param(
    [string]$Version = "latest",
    [string]$BaseUrl = $env:ZCR_BASE_URL,
    [string]$CodexHome = $env:CODEX_HOME,
    [string]$CodexBinary = $(if ($env:CODEX_BIN) { $env:CODEX_BIN } else { "codex" }),
    [switch]$Enable,
    [string]$ResolveOs,
    [string]$ResolveArch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$script:Repository = "antonynz/z-codex-router"
$script:PluginName = "z-codex-router"
$script:MarketplaceName = "z-codex-router"

function Resolve-ZcrPlatform {
    param(
        [Parameter(Mandatory = $true)][string]$Os,
        [Parameter(Mandatory = $true)][string]$Architecture
    )
    $platform = switch -Regex ($Os) {
        "^(Darwin|darwin|macOS|macos)$" { "darwin"; break }
        "^(Linux|linux)$" { "linux"; break }
        "^(Windows_NT|Windows|windows)$" { "windows"; break }
        default { throw "E_PLATFORM_UNSUPPORTED: $Os" }
    }
    $arch = switch -Regex ($Architecture) {
        "^(arm64|aarch64|ARM64|AARCH64)$" { "arm64"; break }
        "^(x86_64|amd64|AMD64|X64|x64)$" { "amd64"; break }
        default { throw "E_ARCH_UNSUPPORTED: $Architecture" }
    }
    return "$platform-$arch"
}

function Test-ZcrVersion {
    param([string]$Value)
    return $Value -match "^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Quiet
    )
    if ($Quiet) {
        & $FilePath @Arguments *> $null
    }
    else {
        & $FilePath @Arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "E_COMMAND_FAILED: $FilePath exited with $LASTEXITCODE"
    }
}

function Download-Https {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Add-Type -AssemblyName System.Net.Http
    $current = [Uri]$Url
    if ($current.Scheme -ne "https") {
        throw "E_URL_INSECURE: only HTTPS URLs are accepted"
    }
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        for ($redirects = 0; $redirects -le 5; $redirects++) {
            $response = $client.GetAsync(
                $current,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            if ($status -ge 300 -and $status -lt 400) {
                $location = $response.Headers.Location
                $response.Dispose()
                if ($null -eq $location) {
                    throw "E_DOWNLOAD: redirect has no Location header"
                }
                $current = if ($location.IsAbsoluteUri) {
                    $location
                }
                else {
                    [System.Uri]::new($current, $location)
                }
                if ($current.Scheme -ne "https") {
                    throw "E_URL_INSECURE: redirect downgraded from HTTPS"
                }
                continue
            }
            if (-not $response.IsSuccessStatusCode) {
                $response.Dispose()
                throw "E_DOWNLOAD: HTTP $status for $current"
            }
            $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream = [System.IO.File]::Open(
                $Destination,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            try {
                $inputStream.CopyTo($outputStream)
                $outputStream.Flush()
            }
            finally {
                $outputStream.Dispose()
                $inputStream.Dispose()
                $response.Dispose()
            }
            return
        }
        throw "E_DOWNLOAD: too many redirects"
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-ExpectedChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$SumsFile,
        [Parameter(Mandatory = $true)][string]$AssetName
    )
    $pattern = "^([0-9A-Fa-f]{64})\s+\*?" + [Regex]::Escape($AssetName) + "$"
    $foundChecksums = @(
        Get-Content -LiteralPath $SumsFile | ForEach-Object {
            if ($_ -match $pattern) { $Matches[1].ToLowerInvariant() }
        }
    )
    if ($foundChecksums.Count -ne 1) {
        throw "E_CHECKSUM_ENTRY: expected one exact checksum for $AssetName"
    }
    return $foundChecksums[0]
}

function Assert-Checksum {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        throw "E_CHECKSUM_MISMATCH: $(Split-Path -Leaf $Path)"
    }
}

function Assert-SafeArchiveEntries {
    param([Parameter(Mandatory = $true)][string[]]$Entries)
    if ($Entries.Count -eq 0) {
        throw "E_ARCHIVE_INVALID: archive is empty"
    }
    $normalized = @()
    foreach ($entryValue in $Entries) {
        $entry = $entryValue -replace "^\./", ""
        if (
            [string]::IsNullOrWhiteSpace($entry) -or
            $entry.StartsWith("/") -or
            $entry.Contains("\") -or
            $entry -notmatch "^[A-Za-z0-9._/-]+$" -or
            ("/$entry/").Contains("/../")
        ) {
            throw "E_ARCHIVE_PATH: unsafe entry: $entryValue"
        }
        $normalized += $entry
    }
    $duplicates = @($normalized | Group-Object | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        throw "E_ARCHIVE_PATH: duplicate entry: $($duplicates[0].Name)"
    }
    return $normalized
}

function Assert-SafeArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$TarBinary
    )
    $entries = @(& $TarBinary -tzf $Archive)
    if ($LASTEXITCODE -ne 0) {
        throw "E_ARCHIVE_INVALID: cannot list archive"
    }
    $normalized = Assert-SafeArchiveEntries -Entries $entries
    $details = @(& $TarBinary -tvzf $Archive)
    if ($LASTEXITCODE -ne 0) {
        throw "E_ARCHIVE_INVALID: cannot inspect archive types"
    }
    foreach ($detail in $details) {
        if ($detail.Length -eq 0 -or ($detail[0] -ne "-" -and $detail[0] -ne "d")) {
            throw "E_ARCHIVE_TYPE: links and special files are rejected"
        }
    }
    $required = @(
        ".agents/plugins/marketplace.json",
        "plugins/z-codex-router/.codex-plugin/plugin.json",
        "plugins/z-codex-router/release/manifest.json",
        "plugins/z-codex-router/bin/routerctl-$Platform-$Architecture.exe"
    )
    foreach ($path in $required) {
        if ($normalized -notcontains $path) {
            throw "E_ARCHIVE_LAYOUT: required path is missing: $path"
        }
    }
}

function Test-SameTree {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    if (-not (Test-Path -LiteralPath $Right -PathType Container)) {
        return $false
    }
    $rightLinks = @(Get-ChildItem -LiteralPath $Right -Force -Recurse |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($rightLinks.Count -gt 0) {
        return $false
    }
    $leftRoot = (Resolve-Path -LiteralPath $Left).Path
    $rightRoot = (Resolve-Path -LiteralPath $Right).Path
    $leftFiles = @{}
    $rightFiles = @{}
    foreach ($file in Get-ChildItem -LiteralPath $leftRoot -File -Force -Recurse) {
        $relative = $file.FullName.Substring($leftRoot.Length).TrimStart([char[]]"\/")
        $leftFiles[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    foreach ($file in Get-ChildItem -LiteralPath $rightRoot -File -Force -Recurse) {
        $relative = $file.FullName.Substring($rightRoot.Length).TrimStart([char[]]"\/")
        $rightFiles[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    if ($leftFiles.Count -ne $rightFiles.Count) {
        return $false
    }
    foreach ($relative in $leftFiles.Keys) {
        if (-not $rightFiles.ContainsKey($relative) -or
            $rightFiles[$relative] -ne $leftFiles[$relative]) {
            return $false
        }
    }
    return $true
}

function Invoke-ZcrInstall {
    [CmdletBinding()]
    param(
        [string]$Version = "latest",
        [string]$BaseUrl = $env:ZCR_BASE_URL,
        [string]$CodexHome = $env:CODEX_HOME,
        [string]$CodexBinary = $(if ($env:CODEX_BIN) { $env:CODEX_BIN } else { "codex" }),
        [switch]$Enable,
        [string]$ResolveOs,
        [string]$ResolveArch
    )

    if ($ResolveOs -or $ResolveArch) {
        if (-not $ResolveOs -or -not $ResolveArch) {
            throw "E_USAGE: -ResolveOs and -ResolveArch must be supplied together"
        }
        Resolve-ZcrPlatform -Os $ResolveOs -Architecture $ResolveArch
        return
    }
    if ($Version -ne "latest" -and -not (Test-ZcrVersion $Version)) {
        throw "E_VERSION_INVALID: expected a semantic version without a leading v"
    }
    if (-not $BaseUrl) {
        if ($Version -eq "latest") {
            $BaseUrl = "https://github.com/$($script:Repository)/releases/latest/download"
        }
        else {
            $BaseUrl = "https://github.com/$($script:Repository)/releases/download/v$Version"
        }
    }
    $BaseUrl = $BaseUrl.TrimEnd("/")
    if (([Uri]$BaseUrl).Scheme -ne "https") {
        throw "E_URL_INSECURE: -BaseUrl must use HTTPS"
    }

    $isWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows
    )
    if (-not $isWindows) {
        throw "E_PLATFORM_UNSUPPORTED: use install.sh on macOS or Linux"
    }
    $pair = Resolve-ZcrPlatform -Os "Windows_NT" -Architecture (
        [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    )
    $platform, $architecture = $pair.Split("-", 2)

    $codexCommand = Get-Command $CodexBinary -ErrorAction SilentlyContinue
    if ($null -eq $codexCommand) {
        throw "E_CODEX_MISSING: install the Codex CLI first"
    }
    $codexPath = $codexCommand.Source
    Invoke-Checked -FilePath $codexPath -Arguments @(
        "plugin", "marketplace", "add", "--help"
    ) -Quiet
    Invoke-Checked -FilePath $codexPath -Arguments @("plugin", "add", "--help") -Quiet

    if (-not $CodexHome) {
        if (-not $HOME) {
            throw "E_CODEX_HOME_REQUIRED: set HOME or CODEX_HOME"
        }
        $CodexHome = Join-Path $HOME ".codex"
    }
    $CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
    $root = [System.IO.Path]::GetPathRoot($CodexHome)
    $userHome = if ($HOME) { [System.IO.Path]::GetFullPath($HOME) } else { "" }
    if ($CodexHome -eq $root -or ($userHome -and $CodexHome -eq $userHome)) {
        throw "E_CODEX_HOME_INVALID: unsafe Codex home"
    }

    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    $codexHomeItem = Get-Item -LiteralPath $CodexHome -Force
    if ($codexHomeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "E_CODEX_HOME_INVALID: Codex home cannot be a reparse point"
    }
    $CodexHome = $codexHomeItem.FullName
    $previousCodexHome = [Environment]::GetEnvironmentVariable(
        "CODEX_HOME",
        [EnvironmentVariableTarget]::Process
    )
    $env:CODEX_HOME = $CodexHome
    $workDir = Join-Path $CodexHome ".zcr-install-$PID-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $workDir | Out-Null
    $sourceRoot = ""
    $versionRoot = ""
    $backupRoot = ""
    $versionBackup = ""
    $completed = $false
    try {
        $asset = "z-codex-router-$platform-$architecture.tar.gz"
        $sumsFile = Join-Path $workDir "SHA256SUMS"
        Download-Https -Url "$BaseUrl/SHA256SUMS" -Destination $sumsFile
        [long]$downloadedBytes = (Get-Item -LiteralPath $sumsFile).Length
        $expected = Get-ExpectedChecksum -SumsFile $sumsFile -AssetName $asset

        $cacheDir = Join-Path $CodexHome "z-codex-router-downloads"
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        if ((Get-Item -LiteralPath $cacheDir -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
            throw "E_PATH_INVALID: cache directory cannot be a reparse point"
        }
        $cacheArchive = Join-Path $cacheDir $asset
        if ((Test-Path -LiteralPath $cacheArchive) -and
            ((Get-Item -LiteralPath $cacheArchive -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) {
            throw "E_PATH_INVALID: cached archive cannot be a reparse point"
        }
        $cacheHit = $false
        if (Test-Path -LiteralPath $cacheArchive -PathType Leaf) {
            $cachedHash = (Get-FileHash -LiteralPath $cacheArchive -Algorithm SHA256).Hash.ToLowerInvariant()
            $cacheHit = $cachedHash -eq $expected
        }
        if (-not $cacheHit) {
            $archiveDownload = Join-Path $workDir $asset
            Download-Https -Url "$BaseUrl/$asset" -Destination $archiveDownload
            $downloadedBytes += (Get-Item -LiteralPath $archiveDownload).Length
            Assert-Checksum -Path $archiveDownload -Expected $expected
            Move-Item -Force -LiteralPath $archiveDownload -Destination $cacheArchive
        }
        Assert-Checksum -Path $cacheArchive -Expected $expected

        $tarCommand = Get-Command "tar.exe" -ErrorAction SilentlyContinue
        if ($null -eq $tarCommand) {
            throw "E_PREREQUISITE: tar.exe is required"
        }
        Assert-SafeArchive -Archive $cacheArchive -Platform $platform `
            -Architecture $architecture -TarBinary $tarCommand.Source
        $stageRoot = Join-Path $workDir "source"
        New-Item -ItemType Directory -Path $stageRoot | Out-Null
        Invoke-Checked -FilePath $tarCommand.Source -Arguments @(
            "-xzf", $cacheArchive, "-C", $stageRoot
        ) -Quiet
        $reparse = @(Get-ChildItem -LiteralPath $stageRoot -Force -Recurse |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($reparse.Count -gt 0) {
            throw "E_ARCHIVE_TYPE: extracted links are rejected"
        }

        $manifestPath = Join-Path $stageRoot "plugins/z-codex-router/release/manifest.json"
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        $resolvedVersion = [string]$manifest.version
        if (-not (Test-ZcrVersion $resolvedVersion)) {
            throw "E_RELEASE_VERSION: release manifest version is invalid"
        }
        if ($Version -ne "latest" -and $resolvedVersion -ne $Version) {
            throw "E_RELEASE_VERSION: requested $Version but archive contains $resolvedVersion"
        }

        $versionParent = Join-Path $CodexHome (
            "z-codex-router-marketplace-versions/$resolvedVersion"
        )
        New-Item -ItemType Directory -Force -Path $versionParent | Out-Null
        if ((Get-Item -LiteralPath $versionParent -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
            throw "E_PATH_INVALID: version directory cannot be a reparse point"
        }
        $versionRoot = Join-Path $versionParent "$platform-$architecture"
        $versionReused = Test-SameTree -Left $stageRoot -Right $versionRoot
        if (-not $versionReused) {
            if (Test-Path -LiteralPath $versionRoot -PathType Leaf) {
                throw "E_SOURCE_CONFLICT: persistent version path is not a directory"
            }
            if (Test-Path -LiteralPath $versionRoot -PathType Container) {
                $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
                $versionBackup = Join-Path $versionParent (
                    ".previous-$platform-$architecture-$stamp-$PID"
                )
                Move-Item -LiteralPath $versionRoot -Destination $versionBackup
            }
            Move-Item -LiteralPath $stageRoot -Destination $versionRoot
        }

        $sourceParent = Join-Path $CodexHome "z-codex-router-marketplaces"
        New-Item -ItemType Directory -Force -Path $sourceParent | Out-Null
        if ((Get-Item -LiteralPath $sourceParent -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
            throw "E_PATH_INVALID: source directory cannot be a reparse point"
        }
        $sourceRoot = Join-Path $sourceParent "$platform-$architecture"
        $sourceReused = Test-SameTree -Left $versionRoot -Right $sourceRoot
        if (-not $sourceReused) {
            if (Test-Path -LiteralPath $sourceRoot -PathType Leaf) {
                throw "E_SOURCE_CONFLICT: persistent marketplace path is not a directory"
            }
            $activeStage = Join-Path $workDir "active-source"
            Copy-Item -LiteralPath $versionRoot -Destination $activeStage -Recurse -Force
            if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
                $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
                $backupRoot = Join-Path $sourceParent ".previous-$platform-$architecture-$stamp-$PID"
                Move-Item -LiteralPath $sourceRoot -Destination $backupRoot
            }
            Move-Item -LiteralPath $activeStage -Destination $sourceRoot
        }

        Invoke-Checked -FilePath $codexPath -Arguments @(
            "plugin", "marketplace", "add", $sourceRoot, "--json"
        )
        Invoke-Checked -FilePath $codexPath -Arguments @(
            "plugin", "add", "$($script:PluginName)@$($script:MarketplaceName)", "--json"
        )

        $launcher = Join-Path $sourceRoot "plugins/z-codex-router/scripts/routerctl.ps1"
        $shellName = if ($PSVersionTable.PSEdition -eq "Core") {
            "pwsh.exe"
        }
        else {
            "powershell.exe"
        }
        $shellPath = Join-Path $PSHOME $shellName
        if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
            $shellCommand = Get-Command $shellName -ErrorAction SilentlyContinue
            if ($null -eq $shellCommand) {
                throw "E_PREREQUISITE: cannot locate the current PowerShell host"
            }
            $shellPath = $shellCommand.Source
        }
        $shellPrefix = @("-NoProfile", "-File", $launcher)
        $current = Join-Path $CodexHome "z-codex-router/current.json"
        if (Test-Path -LiteralPath $current -PathType Leaf) {
            Invoke-Checked -FilePath $shellPath -Arguments ($shellPrefix + @(
                "--codex-home", $CodexHome, "upgrade", "--dry-run"
            ))
            if ($Enable) {
                Invoke-Checked -FilePath $shellPath -Arguments ($shellPrefix + @(
                    "--codex-home", $CodexHome, "upgrade"
                ))
            }
        }
        else {
            Invoke-Checked -FilePath $shellPath -Arguments ($shellPrefix + @(
                "--codex-home", $CodexHome, "dry-run"
            ))
            if ($Enable) {
                Invoke-Checked -FilePath $shellPath -Arguments ($shellPrefix + @(
                    "--codex-home", $CodexHome, "install"
                ))
            }
        }
        if ($Enable) {
            Invoke-Checked -FilePath $shellPath -Arguments ($shellPrefix + @(
                "--codex-home", $CodexHome, "doctor"
            ))
        }

        $completed = $true
        [ordered]@{
            version = $resolvedVersion
            platform = "$platform-$architecture"
            source = $sourceRoot
            versionSource = $versionRoot
            cacheHit = $cacheHit
            versionReused = $versionReused
            sourceReused = $sourceReused
            downloadedBytes = $downloadedBytes
            enabled = [bool]$Enable
            previousSource = $(if ($backupRoot) { $backupRoot } else { $null })
            previousVersionSource = $(if ($versionBackup) { $versionBackup } else { $null })
        } | ConvertTo-Json
    }
    finally {
        if (-not $completed -and $backupRoot -and
            (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            if ($sourceRoot -and (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
                $failedRoot = "$sourceRoot.failed-$PID"
                Move-Item -LiteralPath $sourceRoot -Destination $failedRoot -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $backupRoot -Destination $sourceRoot -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $workDir -PathType Container) {
            Remove-Item -LiteralPath $workDir -Recurse -Force
        }
        if ($null -eq $previousCodexHome) {
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_HOME = $previousCodexHome
        }
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-ZcrInstall @PSBoundParameters
}
