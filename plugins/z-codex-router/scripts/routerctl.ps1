$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$script:Format = "script-v1"
$script:PublicVersion = "1.0.0"
$script:BeginMarker = "<!-- z-codex-router:begin"
$script:EndMarker = "<!-- z-codex-router:end id=z-codex-router -->"
$script:DefaultBudget = 32768
$script:SourceRoot = $null
$script:CodexHome = $null
$script:DoctorCwd = $null
$script:WorkDir = $null
$script:LockDir = $null
$script:LockHeld = $false
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Show-Usage {
    @"
Z Codex Router pure-script control plane

Usage:
  routerctl.ps1 [--source PATH] [--codex-home PATH] dry-run
  routerctl.ps1 [--source PATH] [--codex-home PATH] install
  routerctl.ps1 [--source PATH] [--codex-home PATH] doctor [--cwd PATH]
  routerctl.ps1 [--source PATH] [--codex-home PATH] upgrade [--dry-run]
  routerctl.ps1 [--source PATH] [--codex-home PATH] recover
  routerctl.ps1 [--source PATH] [--codex-home PATH] rollback
  routerctl.ps1 [--source PATH] [--codex-home PATH] uninstall
  routerctl.ps1 [--source PATH] [--codex-home PATH] legacy-cleanup [--dry-run]
  routerctl.ps1 [--source PATH] [--codex-home PATH] profile show|init|validate|reset
  routerctl.ps1 [--source PATH] [--codex-home PATH] profile set TIER MODEL EFFORT
  routerctl.ps1 [--source PATH] [--codex-home PATH] profile restore BACKUP
"@
}

function Fail-Zcr {
    param([string]$Code, [string]$Message)
    throw (New-Object System.InvalidOperationException("$Code`: $Message"))
}

function Write-Lines {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        [Console]::Out.WriteLine($line)
    }
}

function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($Bytes)
        return ([BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant())
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-Sha256File {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) {
        Fail-Zcr "E_PATH_INVALID" "regular file is missing: $Path"
    }
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant())
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function Get-OptionalFileHash {
    param([string]$Path)
    if ([IO.File]::Exists($Path)) {
        return Get-Sha256File $Path
    }
    if ([IO.Directory]::Exists($Path)) {
        Fail-Zcr "E_PATH_INVALID" "expected a file or an absent path: $Path"
    }
    return "absent"
}

function Test-ReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-NoLinks {
    param([string]$Root)
    if (Test-ReparsePoint $Root) {
        Fail-Zcr "E_PATH_INVALID" "managed root cannot be a link: $Root"
    }
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force -Recurse) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail-Zcr "E_PATH_INVALID" "symbolic links are not allowed: $($item.FullName)"
        }
    }
}

function Get-TreeHash {
    param([string]$Root)
    if (-not [IO.Directory]::Exists($Root)) {
        Fail-Zcr "E_PATH_INVALID" "managed tree is missing: $Root"
    }
    Assert-NoLinks $Root
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $rootFull -Force -File -Recurse) {
        $relative = $file.FullName.Substring($rootFull.Length + 1).Replace("\", "/")
        if ($relative.Contains("`n") -or $relative.Contains("`t")) {
            Fail-Zcr "E_PATH_INVALID" "unsupported filename in managed tree"
        }
        $paths.Add($relative)
    }
    if ($paths.Count -eq 0) {
        Fail-Zcr "E_SOURCE_INVALID" "managed tree is empty: $Root"
    }
    $ordered = $paths.ToArray()
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $builder = New-Object Text.StringBuilder
    foreach ($relative in $ordered) {
        $full = [IO.Path]::Combine($rootFull, $relative.Replace([char]'/', [IO.Path]::DirectorySeparatorChar))
        [void]$builder.Append((Get-Sha256File $full))
        [void]$builder.Append("  ")
        [void]$builder.Append($relative)
        [void]$builder.Append("`n")
    }
    return Get-Sha256Bytes ($script:Utf8NoBom.GetBytes($builder.ToString()))
}

function Get-Timestamp {
    return [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
}

function Write-Value {
    param([string]$Path, [string]$Value)
    [IO.File]::WriteAllText($Path, "$Value`n", $script:Utf8NoBom)
}

function Read-Value {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) {
        Fail-Zcr "E_STATE_INVALID" "missing state file: $Path"
    }
    $value = [IO.File]::ReadAllText($Path, $script:Utf8NoBom).TrimEnd("`r", "`n")
    if ([String]::IsNullOrEmpty($value)) {
        Fail-Zcr "E_STATE_INVALID" "empty state file: $Path"
    }
    return $value
}

function Write-AtomicBytes {
    param([string]$Destination, [byte[]]$Bytes)
    $parent = [IO.Path]::GetDirectoryName($Destination)
    if (-not [IO.Directory]::Exists($parent)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }
    $temporary = [IO.Path]::Combine($parent, "." + [IO.Path]::GetFileName($Destination) + "." + [Guid]::NewGuid().ToString("N"))
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    try {
        if ([IO.File]::Exists($Destination)) {
            $replaceBackup = [IO.Path]::Combine($parent, "." + [Guid]::NewGuid().ToString("N") + ".replace")
            [IO.File]::Replace($temporary, $Destination, $replaceBackup, $true)
            if ([IO.File]::Exists($replaceBackup)) {
                [IO.File]::Delete($replaceBackup)
            }
        }
        else {
            [IO.File]::Move($temporary, $Destination)
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Copy-AtomicFile {
    param([string]$Source, [string]$Destination)
    Write-AtomicBytes $Destination ([IO.File]::ReadAllBytes($Source))
}

function Resolve-Paths {
    $scriptDir = [IO.Path]::GetFullPath($PSScriptRoot)
    if ([String]::IsNullOrEmpty($script:SourceRoot)) {
        $script:SourceRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($scriptDir, ".."))
    }
    else {
        $script:SourceRoot = [IO.Path]::GetFullPath($script:SourceRoot)
    }
    if (-not [IO.Directory]::Exists($script:SourceRoot)) {
        Fail-Zcr "E_SOURCE_INVALID" "source does not exist: $($script:SourceRoot)"
    }

    if ([String]::IsNullOrEmpty($script:CodexHome)) {
        if (-not [String]::IsNullOrEmpty($env:CODEX_HOME)) {
            $script:CodexHome = $env:CODEX_HOME
        }
        elseif (-not [String]::IsNullOrEmpty($env:USERPROFILE)) {
            $script:CodexHome = [IO.Path]::Combine($env:USERPROFILE, ".codex")
        }
        else {
            Fail-Zcr "E_CODEX_HOME_REQUIRED" "set CODEX_HOME or USERPROFILE"
        }
    }
    if (-not [IO.Path]::IsPathRooted($script:CodexHome)) {
        Fail-Zcr "E_CODEX_HOME_INVALID" "Codex home must be absolute"
    }
    $script:CodexHome = [IO.Path]::GetFullPath($script:CodexHome)
    $root = [IO.Path]::GetPathRoot($script:CodexHome)
    if ($script:CodexHome.TrimEnd("\", "/") -eq $root.TrimEnd("\", "/")) {
        Fail-Zcr "E_CODEX_HOME_INVALID" "filesystem root is unsafe"
    }
    if ([IO.Directory]::Exists($script:CodexHome) -and (Test-ReparsePoint $script:CodexHome)) {
        Fail-Zcr "E_CODEX_HOME_INVALID" "Codex home cannot be a symbolic link"
    }
    [void][IO.Directory]::CreateDirectory($script:CodexHome)

    $script:RouterRoot = [IO.Path]::Combine($script:CodexHome, "z-codex-router")
    $script:CurrentDir = [IO.Path]::Combine($script:RouterRoot, "current")
    $script:VersionsDir = [IO.Path]::Combine($script:RouterRoot, "versions")
    $script:BackupsDir = [IO.Path]::Combine($script:RouterRoot, "backups")
    $script:TransactionDir = [IO.Path]::Combine($script:RouterRoot, "transaction")
    $script:AgentsFile = [IO.Path]::Combine($script:CodexHome, "AGENTS.md")
    $script:GlobalOverride = [IO.Path]::Combine($script:CodexHome, "AGENTS.override.md")
    $script:ProfileFile = [IO.Path]::Combine($script:CodexHome, "z-codex-router-profile.toml")
    $script:ProfileBackups = [IO.Path]::Combine($script:CodexHome, "z-codex-router-profile-backups")
    $script:LockDir = [IO.Path]::Combine($script:CodexHome, ".z-codex-router.lock")
    $script:WorkDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zcr-" + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($script:WorkDir)
}

function Acquire-Lock {
    try {
        [void](New-Item -ItemType Directory -Path $script:LockDir -ErrorAction Stop)
        $pidPath = [IO.Path]::Combine($script:LockDir, "pid")
        Write-Value $pidPath ([string]$PID)
        $script:LockHeld = $true
    }
    catch {
        if ($_.Exception.Message.StartsWith("E_LOCKED:")) {
            throw
        }
        Fail-Zcr "E_LOCKED" "another Z Codex Router operation is active"
    }
}

function Release-Lock {
    if ($script:LockHeld) {
        $pidPath = [IO.Path]::Combine($script:LockDir, "pid")
        if ([IO.File]::Exists($pidPath)) {
            [IO.File]::Delete($pidPath)
        }
        [IO.Directory]::Delete($script:LockDir, $false)
        $script:LockHeld = $false
    }
}

function Test-Semver {
    param([string]$Version)
    return $Version -match '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
}

function Read-ManifestVersion {
    param([string]$Path, [string]$Kind)
    if (-not [IO.File]::Exists($Path)) {
        Fail-Zcr "E_SOURCE_INVALID" "$Kind manifest is missing"
    }
    $text = [IO.File]::ReadAllText($Path, $script:Utf8NoBom)
    $match = [Regex]::Match($text, '(?m)^\s*"version"\s*:\s*"([^"]+)"')
    if (-not $match.Success -or -not (Test-Semver $match.Groups[1].Value)) {
        Fail-Zcr "E_SOURCE_INVALID" "$Kind manifest version is invalid"
    }
    return $match.Groups[1].Value
}

function Copy-Payload {
    param([string]$Destination)
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($name in @("agents", "core", "profiles", "release", "compatibility.json")) {
        $source = [IO.Path]::Combine($script:SourceRoot, $name)
        if (-not (Test-Path -LiteralPath $source)) {
            Fail-Zcr "E_SOURCE_INVALID" "required payload entry is missing: $name"
        }
        Copy-Item -LiteralPath $source -Destination $Destination -Recurse -Force
    }
}

function Normalize-Profile {
    param([string]$Path, [string]$Kind)
    if (-not [IO.File]::Exists($Path)) {
        Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "profile file is missing: $Path"
    }
    $schemaCount = 0
    $section = ""
    $mapping = @{}
    foreach ($raw in [IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
        $line = [Regex]::Replace($raw.TrimEnd("`r"), '\s*#.*$', "").Trim()
        if ($line.Length -eq 0) { continue }
        if ($line -match '^\[[A-Za-z0-9_.-]+\]$') {
            $section = $line
            if ($Kind -eq "override" -and $section -ne "[routing]") {
                Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "override contains an unknown section"
            }
            continue
        }
        if ($section.Length -eq 0) {
            if ($line -match '^schema_version\s*=\s*1$') {
                $schemaCount++
            }
            elseif ($Kind -eq "override") {
                Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "override contains an unknown top-level key"
            }
            continue
        }
        if ($section -ne "[routing]") { continue }
        $match = [Regex]::Match(
            $line,
            '^(A0|A1|B0|B1|B2|C1|C2|C3)\s*=\s*\{\s*model\s*=\s*"([A-Za-z0-9._-]+)"\s*,\s*effort\s*=\s*"([A-Za-z0-9._-]+)"\s*\}\s*$'
        )
        if (-not $match.Success) {
            Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "invalid routing mapping line"
        }
        $tier = $match.Groups[1].Value
        if ($mapping.ContainsKey($tier)) {
            Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "duplicate tier: $tier"
        }
        $mapping[$tier] = @($match.Groups[2].Value, $match.Groups[3].Value)
    }
    if ($schemaCount -ne 1) {
        Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "profile needs exactly schema_version = 1"
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($tier in @("A0", "A1", "B0", "B1", "B2", "C1", "C2", "C3")) {
        if (-not $mapping.ContainsKey($tier)) {
            Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "missing tier: $tier"
        }
        $model = $mapping[$tier][0]
        $effort = $mapping[$tier][1]
        if ($tier -eq "A0") {
            if ($model -ne "current-qualified-root" -or $effort -ne "runtime-qualified") {
                Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "A0 semantics are fixed"
            }
        }
        else {
            if ($model -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
                $effort -notmatch '^(medium|high|xhigh|max)$') {
                Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "invalid model or effort for $tier"
            }
        }
        $result.Add([PSCustomObject]@{ Tier = $tier; Model = $model; Effort = $effort })
    }
    return $result.ToArray()
}

function Get-NormalizedProfileBytes {
    param([object[]]$Mapping)
    $builder = New-Object Text.StringBuilder
    foreach ($entry in $Mapping) {
        [void]$builder.Append($entry.Tier)
        [void]$builder.Append("|")
        [void]$builder.Append($entry.Model)
        [void]$builder.Append("|")
        [void]$builder.Append($entry.Effort)
        [void]$builder.Append("`n")
    }
    return ,$script:Utf8NoBom.GetBytes($builder.ToString())
}

function Get-CanonicalProfileBytes {
    param([object[]]$Mapping)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append("schema_version = 1`n`n[routing]`n")
    foreach ($entry in $Mapping) {
        [void]$builder.AppendFormat(
            '{0} = {{ model = "{1}", effort = "{2}" }}' + "`n",
            $entry.Tier,
            $entry.Model,
            $entry.Effort
        )
    }
    return ,$script:Utf8NoBom.GetBytes($builder.ToString())
}

function Get-ActivePayloadRoot {
    $versionPath = [IO.Path]::Combine($script:CurrentDir, "version")
    if ([IO.Directory]::Exists($script:CurrentDir) -and [IO.File]::Exists($versionPath)) {
        $version = Read-Value $versionPath
        $root = [IO.Path]::Combine($script:VersionsDir, $version)
        if (-not [IO.Directory]::Exists($root)) {
            Fail-Zcr "E_STATE_INVALID" "active version payload is missing"
        }
        return $root
    }
    return $script:SourceRoot
}

function Validate-EffectiveProfile {
    if ([IO.File]::Exists($script:ProfileFile)) {
        if (Test-ReparsePoint $script:ProfileFile) {
            Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "user override cannot be a link"
        }
        $script:EffectiveProfileMapping = Normalize-Profile $script:ProfileFile "override"
        $script:EffectiveProfileSource = "override"
        $script:EffectiveProfilePath = $script:ProfileFile
    }
    elseif ([IO.Directory]::Exists($script:ProfileFile)) {
        Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "user override must be a regular file"
    }
    else {
        $payload = Get-ActivePayloadRoot
        $path = [IO.Path]::Combine($payload, "profiles", "stable", "current-gpt-5.6-reference.toml")
        $script:EffectiveProfileMapping = Normalize-Profile $path "default"
        $script:EffectiveProfileSource = "default"
        $script:EffectiveProfilePath = $path
    }
    $script:EffectiveProfileHash = Get-Sha256Bytes (Get-NormalizedProfileBytes $script:EffectiveProfileMapping)
}

function Validate-Source {
    Assert-NoLinks $script:SourceRoot
    $releasePath = [IO.Path]::Combine($script:SourceRoot, "release", "manifest.json")
    $pluginPath = [IO.Path]::Combine($script:SourceRoot, ".codex-plugin", "plugin.json")
    $base = Read-ManifestVersion $releasePath "release"
    $local = Read-ManifestVersion $pluginPath "plugin"
    if ($base -ne $script:PublicVersion) {
        Fail-Zcr "E_SOURCE_INVALID" "public source version must remain $($script:PublicVersion)"
    }
    if ($local -ne $base -and -not $local.StartsWith("$base+codex.", [StringComparison]::Ordinal)) {
        Fail-Zcr "E_SOURCE_INVALID" "plugin version must be $base or a +codex cache build"
    }
    foreach ($relative in @(
        "core/managed-block.md",
        "core/router.md",
        "core/policy.md",
        "core/classification.md",
        "core/modes/automation.md",
        "core/modes/business-operations.md",
        "core/modes/content.md",
        "core/modes/design.md",
        "core/modes/engineering.md",
        "core/modes/general.md",
        "core/modes/image.md",
        "core/modes/product.md",
        "core/modes/research.md",
        "core/modes/testing.md",
        "core/modes/video.md",
        "agents/roles/analyst.toml",
        "agents/roles/code_writer.toml",
        "agents/roles/designer.toml",
        "agents/roles/docs_writer.toml",
        "agents/roles/media_creator.toml",
        "agents/roles/reviewer.toml",
        "agents/roles/runtime_validator.toml",
        "profiles/portable/default.toml",
        "profiles/stable/current-gpt-5.6-reference.toml",
        "profiles/candidate/example-next-model.toml",
        "profiles/schema.json",
        "release/manifest.json",
        "compatibility.json"
    )) {
        $path = [IO.Path]::Combine($script:SourceRoot, $relative.Replace([char]'/', [IO.Path]::DirectorySeparatorChar))
        if (-not [IO.File]::Exists($path)) {
            Fail-Zcr "E_SOURCE_INVALID" "required source file is missing: $relative"
        }
    }
    foreach ($skill in @("recover-router", "router-doctor", "setup-router", "uninstall-router", "upgrade-router")) {
        $path = [IO.Path]::Combine($script:SourceRoot, "skills", $skill, "SKILL.md")
        if (-not [IO.File]::Exists($path)) {
            Fail-Zcr "E_SOURCE_INVALID" "required skill is missing: $skill"
        }
    }
    $stable = [IO.Path]::Combine($script:SourceRoot, "profiles", "stable", "current-gpt-5.6-reference.toml")
    [void](Normalize-Profile $stable "default")
    $candidate = [IO.Path]::Combine($script:SourceRoot, "profiles", "candidate", "example-next-model.toml")
    $candidateText = [IO.File]::ReadAllText($candidate, $script:Utf8NoBom)
    if ($candidateText -notmatch '(?m)^\s*status\s*=\s*"disabled"\s*$' -or
        $candidateText -notmatch '(?m)^\s*enabled\s*=\s*false\s*$') {
        Fail-Zcr "E_SOURCE_INVALID" "candidate profile must remain disabled"
    }
    $stage = [IO.Path]::Combine($script:WorkDir, "source-payload")
    Copy-Payload $stage
    $script:SourceBaseVersion = $base
    $script:SourceVersion = $local
    $script:SourcePayloadHash = Get-TreeHash $stage
}

function Get-MarkerCount {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return 0 }
    $text = $script:Utf8NoBom.GetString([IO.File]::ReadAllBytes($Path))
    return [Regex]::Matches($text, [Regex]::Escape($script:BeginMarker)).Count
}

function Get-BomLength {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return 3
    }
    return 0
}

function Get-EolStyle {
    param([byte[]]$Bytes)
    for ($index = 0; $index + 1 -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -eq 13 -and $Bytes[$index + 1] -eq 10) {
            return "crlf"
        }
    }
    return "lf"
}

function Get-ByteSlice {
    param([byte[]]$Bytes, [int]$Start, [int]$Length)
    if ($Length -le 0) { return ,[byte[]]@() }
    $result = New-Object byte[] $Length
    [Array]::Copy($Bytes, $Start, $result, 0, $Length)
    return ,$result
}

function Join-ByteArrays {
    param([object[]]$Arrays)
    $length = 0
    foreach ($array in $Arrays) { $length += ([byte[]]$array).Length }
    $result = New-Object byte[] $length
    $offset = 0
    foreach ($array in $Arrays) {
        $bytes = [byte[]]$array
        if ($bytes.Length -gt 0) {
            [Array]::Copy($bytes, 0, $result, $offset, $bytes.Length)
            $offset += $bytes.Length
        }
    }
    return ,$result
}

function Render-Block {
    param([string]$Version, [string]$PayloadHash, [string]$Eol)
    $templatePath = [IO.Path]::Combine($script:SourceRoot, "core", "managed-block.md")
    $text = [IO.File]::ReadAllText($templatePath, $script:Utf8NoBom)
    $text = $text.Replace("@VERSION@", $Version).Replace("@PAYLOAD_SHA256@", $PayloadHash)
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($Eol -eq "crlf") {
        $text = $text.Replace("`n", "`r`n")
    }
    return ,$script:Utf8NoBom.GetBytes($text)
}

function Test-NewInstall {
    $formatPath = [IO.Path]::Combine($script:CurrentDir, "format")
    return [IO.Directory]::Exists($script:CurrentDir) -and
        [IO.File]::Exists($formatPath) -and
        (([IO.File]::ReadAllText($formatPath, $script:Utf8NoBom).Trim()) -eq $script:Format)
}

function Test-LegacyPresent {
    foreach ($name in @("current.json", "transaction.json", "safe-auto.json", "safe-auto.transaction.json")) {
        if (Test-Path -LiteralPath ([IO.Path]::Combine($script:RouterRoot, $name))) { return $true }
    }
    if ((Get-MarkerCount $script:AgentsFile) -gt 0 -and -not (Test-NewInstall)) { return $true }
    if ([IO.Directory]::Exists($script:RouterRoot) -and -not (Test-NewInstall)) {
        if ((Get-ChildItem -LiteralPath $script:RouterRoot -Force | Select-Object -First 1) -ne $null) {
            return $true
        }
    }
    return $false
}

function Assert-FreshBoundary {
    if (Test-LegacyPresent) {
        Fail-Zcr "E_LEGACY_INSTALL_DETECTED" "legacy Rust/prebuilt state detected; run legacy-cleanup --dry-run, then legacy-cleanup, then install"
    }
}

function Assert-NoTransaction {
    if ([IO.Directory]::Exists($script:TransactionDir)) {
        Fail-Zcr "E_TRANSACTION_PENDING" "run recover before another lifecycle operation"
    }
}

function Assert-NoGlobalOverride {
    if ([IO.File]::Exists($script:GlobalOverride)) {
        if ((Get-Item -LiteralPath $script:GlobalOverride).Length -gt 0) {
            Fail-Zcr "E_GLOBAL_OVERRIDE_ACTIVE" "non-empty global AGENTS.override.md shadows managed AGENTS.md; it was not modified"
        }
    }
    elseif ([IO.Directory]::Exists($script:GlobalOverride)) {
        Fail-Zcr "E_GLOBAL_OVERRIDE_ACTIVE" "global override path is not a regular file"
    }
}

function Validate-ManagedBlock {
    if (-not [IO.Directory]::Exists($script:CurrentDir)) {
        Fail-Zcr "E_NOT_INSTALLED" "script router state is missing"
    }
    if ((Read-Value ([IO.Path]::Combine($script:CurrentDir, "format"))) -ne $script:Format) {
        Fail-Zcr "E_STATE_INVALID" "unsupported state format"
    }
    if (-not [IO.File]::Exists($script:AgentsFile)) {
        Fail-Zcr "E_MANAGED_BLOCK_DRIFT" "AGENTS.md is missing"
    }
    if ((Get-MarkerCount $script:AgentsFile) -ne 1) {
        Fail-Zcr "E_MANAGED_BLOCK_DRIFT" "managed block must appear exactly once"
    }
    $bytes = [IO.File]::ReadAllBytes($script:AgentsFile)
    $bom = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "bom_bytes")))
    $blockLength = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "block_bytes")))
    $prefixLength = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "prefix_bytes")))
    if ($bom -lt 0 -or $blockLength -lt 1 -or $prefixLength -gt $bytes.Length) {
        Fail-Zcr "E_STATE_INVALID" "invalid managed byte offsets"
    }
    $block = Get-ByteSlice $bytes $bom $blockLength
    if ((Get-Sha256Bytes $block) -ne (Read-Value ([IO.Path]::Combine($script:CurrentDir, "block_sha256")))) {
        Fail-Zcr "E_MANAGED_BLOCK_DRIFT" "managed block bytes changed"
    }
    $prefix = Get-ByteSlice $bytes 0 $prefixLength
    if ((Get-Sha256Bytes $prefix) -ne (Read-Value ([IO.Path]::Combine($script:CurrentDir, "prefix_sha256")))) {
        Fail-Zcr "E_MANAGED_BLOCK_DRIFT" "managed prefix or separator changed"
    }
}

function Validate-ActivePayload {
    $version = Read-Value ([IO.Path]::Combine($script:CurrentDir, "version"))
    $expected = Read-Value ([IO.Path]::Combine($script:CurrentDir, "payload_sha256"))
    $payload = [IO.Path]::Combine($script:VersionsDir, $version)
    if (-not [IO.Directory]::Exists($payload) -or (Test-ReparsePoint $payload)) {
        Fail-Zcr "E_PAYLOAD_INVALID" "active payload directory is missing"
    }
    if ((Get-TreeHash $payload) -ne $expected) {
        Fail-Zcr "E_PAYLOAD_INVALID" "active payload hash changed"
    }
}

function Prepare-Agents {
    param([string]$Mode, [string]$Version, [string]$PayloadHash)
    if ($Mode -eq "new") {
        if ([IO.File]::Exists($script:AgentsFile)) {
            $original = [IO.File]::ReadAllBytes($script:AgentsFile)
            $script:AgentsExistedBefore = 1
        }
        elseif ([IO.Directory]::Exists($script:AgentsFile)) {
            Fail-Zcr "E_PATH_INVALID" "AGENTS.md is not a regular file"
        }
        else {
            $original = [byte[]]@()
            $script:AgentsExistedBefore = 0
        }
        $script:BomBytes = Get-BomLength $original
        $script:EolStyle = Get-EolStyle $original
        $remainder = Get-ByteSlice $original $script:BomBytes ($original.Length - $script:BomBytes)
        $bomPart = Get-ByteSlice $original 0 $script:BomBytes
    }
    else {
        Validate-ManagedBlock
        $original = [IO.File]::ReadAllBytes($script:AgentsFile)
        $script:AgentsExistedBefore = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "agents_existed_before")))
        $script:BomBytes = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "bom_bytes")))
        $script:EolStyle = Read-Value ([IO.Path]::Combine($script:CurrentDir, "eol"))
        $oldPrefix = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "prefix_bytes")))
        $remainder = Get-ByteSlice $original $oldPrefix ($original.Length - $oldPrefix)
        $bomPart = Get-ByteSlice $original 0 $script:BomBytes
    }
    $block = Render-Block $Version $PayloadHash $script:EolStyle
    $separator = [byte[]]@()
    if ($remainder.Length -gt 0) {
        if ($script:EolStyle -eq "crlf") {
            $separator = [byte[]](13, 10)
        }
        else {
            $separator = [byte[]](10)
        }
    }
    $script:PreparedAgents = Join-ByteArrays @($bomPart, $block, $separator, $remainder)
    $script:BlockBytes = $block.Length
    $script:BlockHash = Get-Sha256Bytes $block
    $script:PrefixBytes = $bomPart.Length + $block.Length + $separator.Length
    $prefix = Get-ByteSlice $script:PreparedAgents 0 $script:PrefixBytes
    $script:PrefixHash = Get-Sha256Bytes $prefix
    $script:AgentsCommitHash = Get-Sha256Bytes $script:PreparedAgents
}

function Write-CurrentStage {
    param([string]$Stage, [string]$Version, [string]$PayloadHash)
    [void][IO.Directory]::CreateDirectory($Stage)
    Write-Value ([IO.Path]::Combine($Stage, "format")) $script:Format
    Write-Value ([IO.Path]::Combine($Stage, "public_version")) $script:SourceBaseVersion
    Write-Value ([IO.Path]::Combine($Stage, "version")) $Version
    Write-Value ([IO.Path]::Combine($Stage, "payload_sha256")) $PayloadHash
    Write-Value ([IO.Path]::Combine($Stage, "installed_at")) (Get-Timestamp)
    Write-Value ([IO.Path]::Combine($Stage, "agents_existed_before")) ([string]$script:AgentsExistedBefore)
    Write-Value ([IO.Path]::Combine($Stage, "bom_bytes")) ([string]$script:BomBytes)
    Write-Value ([IO.Path]::Combine($Stage, "eol")) $script:EolStyle
    Write-Value ([IO.Path]::Combine($Stage, "block_bytes")) ([string]$script:BlockBytes)
    Write-Value ([IO.Path]::Combine($Stage, "block_sha256")) $script:BlockHash
    Write-Value ([IO.Path]::Combine($Stage, "prefix_bytes")) ([string]$script:PrefixBytes)
    Write-Value ([IO.Path]::Combine($Stage, "prefix_sha256")) $script:PrefixHash
    Write-Value ([IO.Path]::Combine($Stage, "agents_commit_sha256")) $script:AgentsCommitHash
}

function Get-StateTreeHashOptional {
    if ([IO.Directory]::Exists($script:CurrentDir)) {
        return Get-TreeHash $script:CurrentDir
    }
    if (Test-Path -LiteralPath $script:CurrentDir) {
        Fail-Zcr "E_STATE_INVALID" "current state is not a directory"
    }
    return "absent"
}

function Backup-State {
    [void][IO.Directory]::CreateDirectory($script:BackupsDir)
    $backup = [IO.Path]::Combine($script:BackupsDir, "backup-" + (Get-Timestamp) + "-" + $PID)
    [void][IO.Directory]::CreateDirectory($backup)
    if ([IO.File]::Exists($script:AgentsFile)) {
        Write-Value ([IO.Path]::Combine($backup, "agents.present")) "1"
        [IO.File]::Copy($script:AgentsFile, [IO.Path]::Combine($backup, "AGENTS.md"))
        Write-Value ([IO.Path]::Combine($backup, "agents.sha256")) (Get-Sha256File ([IO.Path]::Combine($backup, "AGENTS.md")))
    }
    else {
        Write-Value ([IO.Path]::Combine($backup, "agents.present")) "0"
        Write-Value ([IO.Path]::Combine($backup, "agents.sha256")) "absent"
    }
    if ([IO.Directory]::Exists($script:CurrentDir)) {
        Assert-NoLinks $script:CurrentDir
        Write-Value ([IO.Path]::Combine($backup, "current.present")) "1"
        Copy-Item -LiteralPath $script:CurrentDir -Destination ([IO.Path]::Combine($backup, "current")) -Recurse
        Write-Value ([IO.Path]::Combine($backup, "current.sha256")) (Get-TreeHash ([IO.Path]::Combine($backup, "current")))
    }
    else {
        Write-Value ([IO.Path]::Combine($backup, "current.present")) "0"
        Write-Value ([IO.Path]::Combine($backup, "current.sha256")) "absent"
    }
    return $backup
}

function Validate-Backup {
    param([string]$Backup)
    $backupsFull = [IO.Path]::GetFullPath($script:BackupsDir).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
    $backupFull = [IO.Path]::GetFullPath($Backup)
    if (-not $backupFull.StartsWith($backupsFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($backupFull).StartsWith("backup-", [StringComparison]::Ordinal))) {
        Fail-Zcr "E_TRANSACTION_INVALID" "backup escapes managed directory"
    }
    if (-not [IO.Directory]::Exists($backupFull) -or (Test-ReparsePoint $backupFull)) {
        Fail-Zcr "E_TRANSACTION_INVALID" "managed backup is missing"
    }
    Assert-NoLinks $backupFull
    $agentsPresent = Read-Value ([IO.Path]::Combine($backupFull, "agents.present"))
    if ($agentsPresent -eq "1") {
        $agentsPath = [IO.Path]::Combine($backupFull, "AGENTS.md")
        if (-not [IO.File]::Exists($agentsPath)) {
            Fail-Zcr "E_TRANSACTION_INVALID" "AGENTS.md backup is missing"
        }
        $agentsHash = Read-Value ([IO.Path]::Combine($backupFull, "agents.sha256"))
        if ((Get-Sha256File $agentsPath) -ne $agentsHash) {
            Fail-Zcr "E_TRANSACTION_INVALID" "AGENTS.md backup hash changed"
        }
    }
    elseif ($agentsPresent -eq "0") {
        $agentsHash = Read-Value ([IO.Path]::Combine($backupFull, "agents.sha256"))
        if ($agentsHash -ne "absent" -or (Test-Path -LiteralPath ([IO.Path]::Combine($backupFull, "AGENTS.md")))) {
            Fail-Zcr "E_TRANSACTION_INVALID" "invalid absent AGENTS.md backup"
        }
    }
    else {
        Fail-Zcr "E_TRANSACTION_INVALID" "invalid AGENTS.md backup state"
    }
    $currentPresent = Read-Value ([IO.Path]::Combine($backupFull, "current.present"))
    if ($currentPresent -eq "1") {
        $currentPath = [IO.Path]::Combine($backupFull, "current")
        if (-not [IO.Directory]::Exists($currentPath)) {
            Fail-Zcr "E_TRANSACTION_INVALID" "current state backup is missing"
        }
        $currentHash = Read-Value ([IO.Path]::Combine($backupFull, "current.sha256"))
        if ((Get-TreeHash $currentPath) -ne $currentHash) {
            Fail-Zcr "E_TRANSACTION_INVALID" "current state backup hash changed"
        }
    }
    elseif ($currentPresent -eq "0") {
        $currentHash = Read-Value ([IO.Path]::Combine($backupFull, "current.sha256"))
        if ($currentHash -ne "absent" -or (Test-Path -LiteralPath ([IO.Path]::Combine($backupFull, "current")))) {
            Fail-Zcr "E_TRANSACTION_INVALID" "invalid absent current state backup"
        }
    }
    else {
        Fail-Zcr "E_TRANSACTION_INVALID" "invalid current backup state"
    }
    return [PSCustomObject]@{
        Path = $backupFull
        AgentsPresent = $agentsPresent
        AgentsHash = $agentsHash
        CurrentPresent = $currentPresent
        CurrentHash = $currentHash
    }
}

function Restore-Backup {
    param([string]$Backup)
    $validated = Validate-Backup $Backup
    if ($validated.AgentsPresent -eq "1") {
        Copy-AtomicFile ([IO.Path]::Combine($validated.Path, "AGENTS.md")) $script:AgentsFile
    }
    elseif ([IO.File]::Exists($script:AgentsFile)) {
        [IO.File]::Delete($script:AgentsFile)
    }
    if ([IO.Directory]::Exists($script:CurrentDir)) {
        [IO.Directory]::Delete($script:CurrentDir, $true)
    }
    if ($validated.CurrentPresent -eq "1") {
        Copy-Item -LiteralPath ([IO.Path]::Combine($validated.Path, "current")) -Destination $script:CurrentDir -Recurse
    }
}

function Begin-Transaction {
    param(
        [string]$Action,
        [string]$Backup,
        [string]$AgentsBefore,
        [string]$AgentsAfter,
        [string]$CurrentBefore,
        [string]$CurrentAfter,
        [string]$RemoveVersion,
        [string]$Version
    )
    $temporary = [IO.Path]::Combine($script:RouterRoot, ".transaction-" + $PID)
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
    [void][IO.Directory]::CreateDirectory($temporary)
    Write-Value ([IO.Path]::Combine($temporary, "action")) $Action
    Write-Value ([IO.Path]::Combine($temporary, "backup")) $Backup
    Write-Value ([IO.Path]::Combine($temporary, "agents_before_sha256")) $AgentsBefore
    Write-Value ([IO.Path]::Combine($temporary, "agents_after_sha256")) $AgentsAfter
    Write-Value ([IO.Path]::Combine($temporary, "current_before_sha256")) $CurrentBefore
    Write-Value ([IO.Path]::Combine($temporary, "current_intermediate_sha256")) "absent"
    Write-Value ([IO.Path]::Combine($temporary, "current_after_sha256")) $CurrentAfter
    Write-Value ([IO.Path]::Combine($temporary, "remove_version")) $RemoveVersion
    Write-Value ([IO.Path]::Combine($temporary, "version")) $Version
    Write-Value ([IO.Path]::Combine($temporary, "operation_id")) ([string]$PID)
    [IO.Directory]::Move($temporary, $script:TransactionDir)
}

function Remove-TransactionResidue {
    param([string]$OperationId)
    if ($OperationId -notmatch '^[0-9]+$') {
        Fail-Zcr "E_TRANSACTION_INVALID" "invalid operation identity"
    }
    foreach ($path in @(
        [IO.Path]::Combine($script:RouterRoot, ".current-$OperationId"),
        [IO.Path]::Combine($script:RouterRoot, ".current-previous-$OperationId"),
        [IO.Path]::Combine($script:VersionsDir, ".stage-$OperationId"),
        [IO.Path]::Combine($script:RouterRoot, ".transaction-$OperationId")
    )) {
        if (Test-Path -LiteralPath $path) {
            if (-not [IO.Directory]::Exists($path) -or (Test-ReparsePoint $path)) {
                Fail-Zcr "E_TRANSACTION_INVALID" "unexpected transaction residue type"
            }
            [IO.Directory]::Delete($path, $true)
        }
    }
}

function Invoke-InstallOrUpgrade {
    param([string]$Action, [bool]$DryRun)
    Assert-NoTransaction
    Assert-NoGlobalOverride
    Validate-EffectiveProfile
    Validate-Source
    if (Test-NewInstall) {
        Validate-ManagedBlock
        Validate-ActivePayload
        $currentVersion = Read-Value ([IO.Path]::Combine($script:CurrentDir, "version"))
        $currentHash = Read-Value ([IO.Path]::Combine($script:CurrentDir, "payload_sha256"))
        if ($currentVersion -eq $script:SourceVersion -and $currentHash -eq $script:SourcePayloadHash) {
            Write-Lines @(
                "code=OK_NO_CHANGE",
                "action=$Action",
                "version=$currentVersion",
                "changed=false",
                "profile_source=$($script:EffectiveProfileSource)",
                "profile_hash=$($script:EffectiveProfileHash)"
            )
            return
        }
        if ($Action -ne "upgrade") {
            Fail-Zcr "E_UPGRADE_REQUIRED" "a different script payload is active; use upgrade"
        }
        $mode = "upgrade"
    }
    else {
        Assert-FreshBoundary
        if ($Action -eq "upgrade") {
            Fail-Zcr "E_NOT_INSTALLED" "no script installation exists; use install"
        }
        $mode = "new"
    }
    Prepare-Agents $mode $script:SourceVersion $script:SourcePayloadHash
    $preparedFromAgentsHash = Get-OptionalFileHash $script:AgentsFile
    $preparedFromCurrentHash = Get-StateTreeHashOptional
    if ($DryRun) {
        Write-Lines @(
            "code=OK_DRY_RUN",
            "action=$Action",
            "version=$($script:SourceVersion)",
            "payload_sha256=$($script:SourcePayloadHash)",
            "agents_prefix_bytes=$($script:PrefixBytes)",
            "profile_source=$($script:EffectiveProfileSource)",
            "profile_hash=$($script:EffectiveProfileHash)",
            "changed=true",
            "next_step=start-a-new-task-after-write"
        )
        return
    }

    Acquire-Lock
    Assert-NoTransaction
    if ((Get-OptionalFileHash $script:AgentsFile) -ne $preparedFromAgentsHash -or
        (Get-StateTreeHashOptional) -ne $preparedFromCurrentHash) {
        Fail-Zcr "E_COMMIT_DRIFT" "AGENTS.md or current state changed between preflight and commit"
    }
    Assert-NoGlobalOverride
    [void][IO.Directory]::CreateDirectory($script:RouterRoot)
    [void][IO.Directory]::CreateDirectory($script:VersionsDir)
    [void][IO.Directory]::CreateDirectory($script:BackupsDir)
    $backup = Backup-State
    $destination = [IO.Path]::Combine($script:VersionsDir, $script:SourceVersion)
    $removeVersion = "0"
    if ([IO.Directory]::Exists($destination)) {
        if ((Get-TreeHash $destination) -ne $script:SourcePayloadHash) {
            Fail-Zcr "E_PAYLOAD_CONFLICT" "local version path already contains different bytes"
        }
    }
    elseif (Test-Path -LiteralPath $destination) {
        Fail-Zcr "E_PAYLOAD_CONFLICT" "local version path is not a directory"
    }
    else {
        $versionStage = [IO.Path]::Combine($script:VersionsDir, ".stage-" + $PID)
        Copy-Payload $versionStage
        if ((Get-TreeHash $versionStage) -ne $script:SourcePayloadHash) {
            Fail-Zcr "E_SOURCE_INVALID" "staged payload hash changed"
        }
        [IO.Directory]::Move($versionStage, $destination)
        $removeVersion = "1"
    }
    $currentStage = [IO.Path]::Combine($script:RouterRoot, ".current-" + $PID)
    Write-CurrentStage $currentStage $script:SourceVersion $script:SourcePayloadHash
    $agentsBefore = Get-OptionalFileHash $script:AgentsFile
    $agentsAfter = Get-Sha256Bytes $script:PreparedAgents
    $currentBefore = Get-StateTreeHashOptional
    $currentAfter = Get-TreeHash $currentStage
    Begin-Transaction $Action $backup $agentsBefore $agentsAfter $currentBefore $currentAfter $removeVersion $script:SourceVersion
    Write-AtomicBytes $script:AgentsFile $script:PreparedAgents
    $oldCurrent = [IO.Path]::Combine($script:RouterRoot, ".current-previous-" + $PID)
    if ([IO.Directory]::Exists($script:CurrentDir)) {
        [IO.Directory]::Move($script:CurrentDir, $oldCurrent)
    }
    [IO.Directory]::Move($currentStage, $script:CurrentDir)
    if ([IO.Directory]::Exists($oldCurrent)) { [IO.Directory]::Delete($oldCurrent, $true) }
    [IO.Directory]::Delete($script:TransactionDir, $true)
    Release-Lock
    Write-Lines @(
        "code=OK_ENABLED",
        "action=$Action",
        "version=$($script:SourceVersion)",
        "payload_sha256=$($script:SourcePayloadHash)",
        "backup=$backup",
        "changed=true",
        "profile_source=$($script:EffectiveProfileSource)",
        "profile_hash=$($script:EffectiveProfileHash)",
        "next_step=start-a-new-task"
    )
}

function Read-Budget {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $values = New-Object System.Collections.Generic.List[int]
    foreach ($raw in [IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
        $line = [Regex]::Replace($raw, '\s*#.*$', "")
        $match = [Regex]::Match($line, '^\s*project_doc_max_bytes\s*=\s*([0-9]+)\s*$')
        if ($match.Success) { $values.Add([int]$match.Groups[1].Value) }
    }
    if ($values.Count -gt 1) {
        Fail-Zcr "E_CONFIG_INVALID" "duplicate project_doc_max_bytes in $Path"
    }
    if ($values.Count -eq 1) { return $values[0] }
    return $null
}

function Get-DirectoryChain {
    param([string]$Start)
    $result = New-Object System.Collections.Generic.List[string]
    $directory = [IO.Path]::GetFullPath($Start)
    while ($true) {
        $result.Add($directory)
        $parent = [IO.Directory]::GetParent($directory)
        if ($parent -eq $null) { break }
        $directory = $parent.FullName
    }
    $array = $result.ToArray()
    [Array]::Reverse($array)
    return $array
}

function Invoke-Doctor {
    Assert-NoTransaction
    if (Test-LegacyPresent) {
        Fail-Zcr "E_LEGACY_INSTALL_DETECTED" "legacy state requires explicit legacy-cleanup before a fresh script install"
    }
    if (-not (Test-NewInstall)) {
        $overrideState = "absent"
        if ([IO.File]::Exists($script:GlobalOverride) -and (Get-Item -LiteralPath $script:GlobalOverride).Length -gt 0) {
            $overrideState = "active"
        }
        Write-Lines @("code=OK_NOT_ENABLED", "changed=false", "global_override=$overrideState")
        return
    }
    Assert-NoGlobalOverride
    Validate-ManagedBlock
    Validate-ActivePayload
    Validate-EffectiveProfile
    if ([String]::IsNullOrEmpty($script:DoctorCwd)) {
        $cwd = [IO.Path]::GetFullPath((Get-Location).Path)
    }
    else {
        if (-not [IO.Directory]::Exists($script:DoctorCwd)) {
            Fail-Zcr "E_CWD_INVALID" "doctor cwd does not exist"
        }
        $cwd = [IO.Path]::GetFullPath($script:DoctorCwd)
    }
    $budget = $script:DefaultBudget
    $value = Read-Budget ([IO.Path]::Combine($script:CodexHome, "config.toml"))
    if ($value -ne $null) { $budget = $value }
    $instructionCount = 0
    foreach ($directory in Get-DirectoryChain $cwd) {
        $value = Read-Budget ([IO.Path]::Combine($directory, ".codex", "config.toml"))
        if ($value -ne $null) { $budget = $value }
        $override = [IO.Path]::Combine($directory, "AGENTS.override.md")
        $agents = [IO.Path]::Combine($directory, "AGENTS.md")
        if ([IO.File]::Exists($override) -and (Get-Item -LiteralPath $override).Length -gt 0) {
            $instructionCount++
        }
        elseif ([IO.File]::Exists($agents)) {
            $instructionCount++
        }
    }
    if ($budget -le 0) {
        Fail-Zcr "E_CONFIG_INVALID" "project_doc_max_bytes must be positive"
    }
    $bom = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "bom_bytes")))
    $blockBytes = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "block_bytes")))
    $blockEnd = $bom + $blockBytes
    if ($blockEnd -gt $budget) {
        Fail-Zcr "E_MANAGED_BLOCK_OUTSIDE_INSTRUCTION_BUDGET" "managed block ends at byte $blockEnd, beyond effective budget $budget"
    }
    Write-Lines @(
        "code=OK_ENABLED",
        "version=$(Read-Value ([IO.Path]::Combine($script:CurrentDir, "version")))",
        "payload_sha256=$(Read-Value ([IO.Path]::Combine($script:CurrentDir, "payload_sha256")))",
        "instruction_source=$($script:AgentsFile)",
        "managed_block_start=$bom",
        "managed_block_end=$blockEnd",
        "project_doc_max_bytes=$budget",
        "instruction_cwd=$cwd",
        "project_instruction_count=$instructionCount",
        "profile_source=$($script:EffectiveProfileSource)",
        "profile_path=$($script:EffectiveProfilePath)",
        "profile_hash=$($script:EffectiveProfileHash)",
        "changed=false"
    )
}

function Invoke-Recover {
    if (-not [IO.Directory]::Exists($script:TransactionDir)) {
        Fail-Zcr "E_NO_TRANSACTION" "no pending transaction exists"
    }
    Acquire-Lock
    $backup = Read-Value ([IO.Path]::Combine($script:TransactionDir, "backup"))
    $agentsBefore = Read-Value ([IO.Path]::Combine($script:TransactionDir, "agents_before_sha256"))
    $agentsAfter = Read-Value ([IO.Path]::Combine($script:TransactionDir, "agents_after_sha256"))
    $currentBefore = Read-Value ([IO.Path]::Combine($script:TransactionDir, "current_before_sha256"))
    $currentIntermediate = Read-Value ([IO.Path]::Combine($script:TransactionDir, "current_intermediate_sha256"))
    $currentAfter = Read-Value ([IO.Path]::Combine($script:TransactionDir, "current_after_sha256"))
    $operationId = Read-Value ([IO.Path]::Combine($script:TransactionDir, "operation_id"))
    if ($currentIntermediate -ne "absent") {
        Fail-Zcr "E_TRANSACTION_INVALID" "unsupported current-state intermediate"
    }
    $validatedBackup = Validate-Backup $backup
    if ($validatedBackup.AgentsHash -ne $agentsBefore -or
        $validatedBackup.CurrentHash -ne $currentBefore) {
        Fail-Zcr "E_TRANSACTION_INVALID" "transaction before hashes do not match its backup"
    }
    $actualAgents = Get-OptionalFileHash $script:AgentsFile
    $actualCurrent = Get-StateTreeHashOptional
    if ($actualAgents -ne $agentsBefore -and $actualAgents -ne $agentsAfter) {
        Fail-Zcr "E_TRANSACTION_DRIFT" "AGENTS.md changed outside the pending transaction"
    }
    if ($actualCurrent -ne $currentBefore -and
        $actualCurrent -ne $currentIntermediate -and
        $actualCurrent -ne $currentAfter) {
        Fail-Zcr "E_TRANSACTION_DRIFT" "current state changed outside the pending transaction"
    }
    Restore-Backup $backup
    $removeVersion = Read-Value ([IO.Path]::Combine($script:TransactionDir, "remove_version"))
    $version = Read-Value ([IO.Path]::Combine($script:TransactionDir, "version"))
    if ($removeVersion -eq "1" -and $version.Length -gt 0) {
        if ($version -notmatch '^[0-9A-Za-z.+-]+$') {
            Fail-Zcr "E_TRANSACTION_INVALID" "invalid staged version identity"
        }
        $path = [IO.Path]::Combine($script:VersionsDir, $version)
        if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path, $true) }
    }
    Remove-TransactionResidue $operationId
    [IO.Directory]::Delete($script:TransactionDir, $true)
    if (-not [IO.Directory]::Exists($script:CurrentDir) -and (Get-MarkerCount $script:AgentsFile) -eq 0) {
        [IO.Directory]::Delete($script:RouterRoot, $true)
    }
    Release-Lock
    Write-Lines @("code=OK_RECOVERED", "action=recover", "backup=$backup", "changed=true")
}

function Invoke-Rollback {
    Assert-NoTransaction
    if (-not (Test-NewInstall)) { Fail-Zcr "E_NOT_INSTALLED" "no script installation exists" }
    Validate-ManagedBlock
    Validate-ActivePayload
    $expected = Read-Value ([IO.Path]::Combine($script:CurrentDir, "agents_commit_sha256"))
    if ((Get-Sha256File $script:AgentsFile) -ne $expected) {
        Fail-Zcr "E_ROLLBACK_DRIFT" "AGENTS.md changed since the completed lifecycle operation"
    }
    $preparedFromCurrentHash = Get-StateTreeHashOptional
    $latest = Get-ChildItem -LiteralPath $script:BackupsDir -Force -Directory |
        Where-Object { $_.Name.StartsWith("backup-", [StringComparison]::Ordinal) } |
        Sort-Object Name |
        Select-Object -Last 1
    if ($latest -eq $null) { Fail-Zcr "E_NO_BACKUP" "no managed rollback backup exists" }
    Acquire-Lock
    $beforeAgents = Get-OptionalFileHash $script:AgentsFile
    $beforeCurrent = Get-StateTreeHashOptional
    if ($beforeAgents -ne $expected -or $beforeCurrent -ne $preparedFromCurrentHash) {
        Fail-Zcr "E_COMMIT_DRIFT" "AGENTS.md or current state changed between preflight and rollback"
    }
    $validatedBackup = Validate-Backup $latest.FullName
    $afterAgents = $validatedBackup.AgentsHash
    $afterCurrent = $validatedBackup.CurrentHash
    $safety = Backup-State
    Begin-Transaction "rollback" $safety $beforeAgents $afterAgents $beforeCurrent $afterCurrent "0" "-"
    Restore-Backup $latest.FullName
    [IO.Directory]::Delete($script:TransactionDir, $true)
    if (-not [IO.Directory]::Exists($script:CurrentDir) -and (Get-MarkerCount $script:AgentsFile) -eq 0) {
        [IO.Directory]::Delete($script:RouterRoot, $true)
    }
    Release-Lock
    Write-Lines @("code=OK_ROLLED_BACK", "action=rollback", "backup=$($latest.FullName)", "changed=true", "next_step=start-a-new-task")
}

function Get-UninstallAgents {
    Validate-ManagedBlock
    $bytes = [IO.File]::ReadAllBytes($script:AgentsFile)
    $prefix = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "prefix_bytes")))
    $bom = [int](Read-Value ([IO.Path]::Combine($script:CurrentDir, "bom_bytes")))
    $bomPart = Get-ByteSlice $bytes 0 $bom
    $remainder = Get-ByteSlice $bytes $prefix ($bytes.Length - $prefix)
    return Join-ByteArrays @($bomPart, $remainder)
}

function Invoke-Uninstall {
    Assert-NoTransaction
    if ((Test-LegacyPresent) -and -not (Test-NewInstall)) {
        Fail-Zcr "E_LEGACY_INSTALL_DETECTED" "use legacy-cleanup for the old Rust installation"
    }
    if (-not (Test-NewInstall)) {
        Write-Lines @("code=OK_NOT_ENABLED", "action=uninstall", "changed=false")
        return
    }
    Validate-ManagedBlock
    Validate-ActivePayload
    Validate-EffectiveProfile
    $prepared = Get-UninstallAgents
    $existed = Read-Value ([IO.Path]::Combine($script:CurrentDir, "agents_existed_before"))
    $preparedFromAgentsHash = Get-OptionalFileHash $script:AgentsFile
    $preparedFromCurrentHash = Get-StateTreeHashOptional
    Acquire-Lock
    if ((Get-OptionalFileHash $script:AgentsFile) -ne $preparedFromAgentsHash -or
        (Get-StateTreeHashOptional) -ne $preparedFromCurrentHash) {
        Fail-Zcr "E_COMMIT_DRIFT" "AGENTS.md or current state changed between preflight and commit"
    }
    $backup = Backup-State
    $agentsBefore = Get-OptionalFileHash $script:AgentsFile
    if ($existed -eq "0" -and $prepared.Length -eq 0) { $agentsAfter = "absent" }
    else { $agentsAfter = Get-Sha256Bytes $prepared }
    $currentBefore = Get-StateTreeHashOptional
    Begin-Transaction "uninstall" $backup $agentsBefore $agentsAfter $currentBefore "absent" "0" "-"
    if ($agentsAfter -eq "absent") {
        [IO.File]::Delete($script:AgentsFile)
    }
    else {
        Write-AtomicBytes $script:AgentsFile $prepared
    }
    [IO.Directory]::Delete($script:CurrentDir, $true)
    [IO.Directory]::Delete($script:TransactionDir, $true)
    Release-Lock
    [IO.Directory]::Delete($script:RouterRoot, $true)
    $profilePreserved = [IO.File]::Exists($script:ProfileFile).ToString().ToLowerInvariant()
    Write-Lines @("code=OK_NOT_ENABLED", "action=uninstall", "changed=true", "profile_preserved=$profilePreserved", "next_step=start-a-new-task")
}

function Find-ByteSequence {
    param([byte[]]$Haystack, [byte[]]$Needle)
    $result = New-Object System.Collections.Generic.List[int]
    if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) { return ,$result.ToArray() }
    for ($index = 0; $index -le $Haystack.Length - $Needle.Length; $index++) {
        $match = $true
        for ($offset = 0; $offset -lt $Needle.Length; $offset++) {
            if ($Haystack[$index + $offset] -ne $Needle[$offset]) {
                $match = $false
                break
            }
        }
        if ($match) { $result.Add($index) }
    }
    return ,$result.ToArray()
}

function Invoke-LegacyCleanup {
    param([bool]$DryRun)
    if (-not (Test-LegacyPresent)) {
        Write-Lines @("code=OK_NO_LEGACY_INSTALL", "action=legacy-cleanup", "changed=false")
        return
    }
    if (Test-Path -LiteralPath ([IO.Path]::Combine($script:RouterRoot, "transaction.json"))) {
        Fail-Zcr "E_LEGACY_TRANSACTION_PENDING" "use the legacy controller recover command before cleanup"
    }
    foreach ($name in @("safe-auto.json", "safe-auto.transaction.json")) {
        if (Test-Path -LiteralPath ([IO.Path]::Combine($script:RouterRoot, $name))) {
            Fail-Zcr "E_LEGACY_SAFE_AUTO_STATE" "run the legacy safe-auto restore command before cleanup"
        }
    }
    $currentJson = [IO.Path]::Combine($script:RouterRoot, "current.json")
    if (-not [IO.File]::Exists($currentJson) -or -not [IO.File]::Exists($script:AgentsFile)) {
        Fail-Zcr "E_LEGACY_STATE_INVALID" "legacy current.json and AGENTS.md are required"
    }
    $stateText = [IO.File]::ReadAllText($currentJson, $script:Utf8NoBom)
    $versionMatch = [Regex]::Match($stateText, '(?m)^\s*"version"\s*:\s*"([^"]+)"')
    $hashMatch = [Regex]::Match($stateText, '(?m)^\s*"payload_sha256"\s*:\s*"([0-9a-fA-F]{64})"')
    if (-not $versionMatch.Success -or -not (Test-Semver $versionMatch.Groups[1].Value) -or -not $hashMatch.Success) {
        Fail-Zcr "E_LEGACY_STATE_INVALID" "legacy state identity is invalid"
    }
    $legacyVersion = $versionMatch.Groups[1].Value
    $legacyHash = $hashMatch.Groups[1].Value.ToLowerInvariant()
    $bytes = [IO.File]::ReadAllBytes($script:AgentsFile)
    $beginNeedle = $script:Utf8NoBom.GetBytes($script:BeginMarker)
    $endNeedle = $script:Utf8NoBom.GetBytes($script:EndMarker)
    $begins = Find-ByteSequence $bytes $beginNeedle
    $ends = Find-ByteSequence $bytes $endNeedle
    if ($begins.Length -ne 1 -or $ends.Length -ne 1 -or $ends[0] -le $begins[0]) {
        Fail-Zcr "E_LEGACY_BLOCK_DRIFT" "legacy managed block markers are not unique and complete"
    }
    $lineEnd = $begins[0]
    while ($lineEnd -lt $bytes.Length -and $bytes[$lineEnd] -ne 10) { $lineEnd++ }
    $beginLine = $script:Utf8NoBom.GetString((Get-ByteSlice $bytes $begins[0] ($lineEnd - $begins[0]))).TrimEnd("`r")
    if (-not $beginLine.Contains(" version=$legacyVersion ") -or
        -not $beginLine.Contains(" sha256=$legacyHash ") -or
        -not $beginLine.Contains(" protocol=1")) {
        Fail-Zcr "E_LEGACY_BLOCK_DRIFT" "legacy block identity does not match current.json"
    }
    $finish = $ends[0] + $endNeedle.Length
    if ($finish -lt $bytes.Length -and $bytes[$finish] -eq 13) { $finish++ }
    if ($finish -lt $bytes.Length -and $bytes[$finish] -eq 10) { $finish++ }
    Assert-NoLinks $script:RouterRoot
    $legacyAgentsHash = Get-Sha256File $script:AgentsFile
    $legacyRouterHash = Get-TreeHash $script:RouterRoot
    if ($DryRun) {
        Write-Lines @(
            "code=OK_LEGACY_CLEANUP_DRY_RUN",
            "action=legacy-cleanup",
            "legacy_version=$legacyVersion",
            "legacy_payload_sha256=$legacyHash",
            "managed_block_start=$($begins[0])",
            "managed_block_end=$finish",
            "changed=false",
            "next_step=run-legacy-cleanup-then-fresh-install"
        )
        return
    }
    Acquire-Lock
    if ((Get-Sha256File $script:AgentsFile) -ne $legacyAgentsHash -or
        (Get-TreeHash $script:RouterRoot) -ne $legacyRouterHash) {
        Fail-Zcr "E_COMMIT_DRIFT" "legacy AGENTS.md or Router state changed before cleanup"
    }
    $legacyBackups = [IO.Path]::Combine($script:CodexHome, "z-codex-router-legacy-backups")
    $backup = [IO.Path]::Combine($legacyBackups, "backup-" + (Get-Timestamp) + "-" + $PID)
    [void][IO.Directory]::CreateDirectory($backup)
    [IO.File]::Copy($script:AgentsFile, [IO.Path]::Combine($backup, "AGENTS.md"))
    $config = [IO.Path]::Combine($script:CodexHome, "config.toml")
    if ([IO.File]::Exists($config)) { [IO.File]::Copy($config, [IO.Path]::Combine($backup, "config.toml")) }
    Copy-Item -LiteralPath $script:RouterRoot -Destination ([IO.Path]::Combine($backup, "router-state")) -Recurse
    Write-Value ([IO.Path]::Combine($backup, "agents.sha256")) (Get-Sha256File ([IO.Path]::Combine($backup, "AGENTS.md")))
    Write-Value ([IO.Path]::Combine($backup, "legacy.version")) $legacyVersion
    Write-Value ([IO.Path]::Combine($backup, "legacy.payload_sha256")) $legacyHash
    $start = $begins[0]
    if ($start -gt 3) {
        if ($beginLine.Contains(" separator=two-newlines ") -and $start -ge 2) { $start -= 2 }
        elseif ($beginLine.Contains(" separator=one-newline ") -and $start -ge 1) { $start -= 1 }
    }
    $prefix = Get-ByteSlice $bytes 0 $start
    $suffix = Get-ByteSlice $bytes $finish ($bytes.Length - $finish)
    $prepared = Join-ByteArrays @($prefix, $suffix)
    if ($prepared.Length -eq 0) { [IO.File]::Delete($script:AgentsFile) }
    else { Write-AtomicBytes $script:AgentsFile $prepared }
    [IO.Directory]::Delete($script:RouterRoot, $true)
    Release-Lock
    Write-Lines @("code=OK_LEGACY_CLEANED", "action=legacy-cleanup", "legacy_version=$legacyVersion", "backup=$backup", "changed=true", "next_step=run-fresh-install")
}

function Invoke-Profile {
    param([string]$Operation, [string[]]$Arguments)
    switch ($Operation) {
        { $_ -eq "show" -or $_ -eq "validate" } {
            Validate-EffectiveProfile
            Write-Lines @(
                "code=OK_PROFILE",
                "action=profile-$Operation",
                "profile_source=$($script:EffectiveProfileSource)",
                "profile_path=$($script:EffectiveProfilePath)",
                "profile_hash=$($script:EffectiveProfileHash)",
                "changed=false"
            )
            foreach ($entry in $script:EffectiveProfileMapping) {
                [Console]::Out.WriteLine("$($entry.Tier)|$($entry.Model)|$($entry.Effort)")
            }
            break
        }
        "init" {
            if (Test-Path -LiteralPath $script:ProfileFile) {
                Fail-Zcr "E_PROFILE_OVERRIDE_EXISTS" "user override already exists"
            }
            Validate-EffectiveProfile
            Acquire-Lock
            if (Test-Path -LiteralPath $script:ProfileFile) {
                Fail-Zcr "E_PROFILE_OVERRIDE_EXISTS" "user override appeared before commit"
            }
            Write-AtomicBytes $script:ProfileFile (Get-CanonicalProfileBytes $script:EffectiveProfileMapping)
            Release-Lock
            $checked = Normalize-Profile $script:ProfileFile "override"
            Write-Lines @("code=OK_PROFILE_INITIALIZED", "action=profile-init", "profile_path=$($script:ProfileFile)", "profile_hash=$(Get-Sha256Bytes (Get-NormalizedProfileBytes $checked))", "changed=true")
            break
        }
        "set" {
            if ($Arguments.Count -ne 3) { Fail-Zcr "E_USAGE" "profile set needs TIER MODEL EFFORT" }
            $tier = $Arguments[0]
            $model = $Arguments[1]
            $effort = $Arguments[2]
            if ($tier -notmatch '^(A0|A1|B0|B1|B2|C1|C2|C3)$') {
                Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "unknown tier"
            }
            if ($tier -eq "A0") {
                if ($model -ne "current-qualified-root" -or $effort -ne "runtime-qualified") {
                    Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "A0 semantics are fixed"
                }
            }
            elseif ($model -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
                $effort -notmatch '^(medium|high|xhigh|max)$') {
                Fail-Zcr "E_PROFILE_OVERRIDE_INVALID" "invalid model or effort"
            }
            Validate-EffectiveProfile
            $profileBeforeHash = Get-OptionalFileHash $script:ProfileFile
            $updated = New-Object System.Collections.Generic.List[object]
            foreach ($entry in $script:EffectiveProfileMapping) {
                if ($entry.Tier -eq $tier) {
                    $updated.Add([PSCustomObject]@{ Tier = $tier; Model = $model; Effort = $effort })
                }
                else { $updated.Add($entry) }
            }
            $canonical = Get-CanonicalProfileBytes $updated.ToArray()
            $temporary = [IO.Path]::Combine($script:WorkDir, "profile-updated.toml")
            [IO.File]::WriteAllBytes($temporary, $canonical)
            $checked = Normalize-Profile $temporary "override"
            Acquire-Lock
            if ((Get-OptionalFileHash $script:ProfileFile) -ne $profileBeforeHash) {
                Fail-Zcr "E_PROFILE_OVERRIDE_DRIFT" "override changed before profile set commit"
            }
            Write-AtomicBytes $script:ProfileFile $canonical
            Release-Lock
            Write-Lines @("code=OK_PROFILE_SET", "action=profile-set", "tier=$tier", "profile_path=$($script:ProfileFile)", "profile_hash=$(Get-Sha256Bytes (Get-NormalizedProfileBytes $checked))", "changed=true")
            break
        }
        "reset" {
            if (-not [IO.File]::Exists($script:ProfileFile) -or (Test-ReparsePoint $script:ProfileFile)) {
                Fail-Zcr "E_PROFILE_OVERRIDE_MISSING" "user override does not exist"
            }
            [void](Normalize-Profile $script:ProfileFile "override")
            $profileBeforeHash = Get-Sha256File $script:ProfileFile
            Acquire-Lock
            if ((Get-Sha256File $script:ProfileFile) -ne $profileBeforeHash) {
                Fail-Zcr "E_PROFILE_OVERRIDE_DRIFT" "override changed before reset commit"
            }
            [void][IO.Directory]::CreateDirectory($script:ProfileBackups)
            $backup = [IO.Path]::Combine($script:ProfileBackups, "backup-" + (Get-Timestamp) + "-" + $PID + ".toml")
            [IO.File]::Copy($script:ProfileFile, $backup)
            Write-Value "$backup.sha256" (Get-Sha256File $backup)
            if ((Get-Sha256File $script:ProfileFile) -ne (Get-Sha256File $backup)) {
                Fail-Zcr "E_PROFILE_OVERRIDE_DRIFT" "override changed while reset backup was created"
            }
            [IO.File]::Delete($script:ProfileFile)
            Release-Lock
            Write-Lines @("code=OK_PROFILE_RESET", "action=profile-reset", "backup=$backup", "changed=true")
            break
        }
        "restore" {
            if ($Arguments.Count -ne 1) { Fail-Zcr "E_USAGE" "profile restore needs BACKUP" }
            if (Test-Path -LiteralPath $script:ProfileFile) {
                Fail-Zcr "E_PROFILE_OVERRIDE_EXISTS" "refusing to overwrite an existing user override"
            }
            $requested = [IO.Path]::GetFullPath($Arguments[0])
            $root = [IO.Path]::GetFullPath($script:ProfileBackups).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
            if (-not $requested.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([IO.Path]::GetFileName($requested) -match '^backup-.*\.toml$')) {
                Fail-Zcr "E_PROFILE_BACKUP_INVALID" "backup must be inside the managed backup directory"
            }
            if (-not [IO.File]::Exists($requested) -or (Test-ReparsePoint $requested) -or
                -not [IO.File]::Exists("$requested.sha256")) {
                Fail-Zcr "E_PROFILE_BACKUP_INVALID" "backup or checksum metadata is missing"
            }
            if ((Get-Sha256File $requested) -ne (Read-Value "$requested.sha256")) {
                Fail-Zcr "E_PROFILE_BACKUP_INVALID" "backup hash changed"
            }
            $checked = Normalize-Profile $requested "override"
            Acquire-Lock
            if (Test-Path -LiteralPath $script:ProfileFile) {
                Fail-Zcr "E_PROFILE_OVERRIDE_EXISTS" "user override appeared before restore commit"
            }
            Copy-AtomicFile $requested $script:ProfileFile
            Release-Lock
            Write-Lines @("code=OK_PROFILE_RESTORED", "action=profile-restore", "profile_path=$($script:ProfileFile)", "profile_hash=$(Get-Sha256Bytes (Get-NormalizedProfileBytes $checked))", "changed=true")
            break
        }
        default { Fail-Zcr "E_USAGE" "unknown profile command: $Operation" }
    }
}

function Invoke-Main {
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in $args) { $arguments.Add([string]$argument) }
    while ($arguments.Count -gt 0) {
        $value = $arguments[0]
        if ($value -eq "--source") {
            if ($arguments.Count -lt 2) { Fail-Zcr "E_USAGE" "--source needs a path" }
            $script:SourceRoot = $arguments[1]
            $arguments.RemoveRange(0, 2)
        }
        elseif ($value -eq "--codex-home") {
            if ($arguments.Count -lt 2) { Fail-Zcr "E_USAGE" "--codex-home needs a path" }
            $script:CodexHome = $arguments[1]
            $arguments.RemoveRange(0, 2)
        }
        elseif ($value -eq "-h" -or $value -eq "--help") {
            Show-Usage
            return
        }
        elseif ($value.StartsWith("-", [StringComparison]::Ordinal)) {
            Fail-Zcr "E_USAGE" "unknown global option: $value"
        }
        else { break }
    }
    if ($arguments.Count -lt 1) {
        Show-Usage
        Fail-Zcr "E_USAGE" "a command is required"
    }
    $command = $arguments[0]
    $arguments.RemoveAt(0)
    Resolve-Paths
    switch ($command) {
        "dry-run" {
            if ($arguments.Count -ne 0) { Fail-Zcr "E_USAGE" "dry-run takes no arguments" }
            Invoke-InstallOrUpgrade "install" $true
        }
        "install" {
            if ($arguments.Count -ne 0) { Fail-Zcr "E_USAGE" "install takes no arguments" }
            Invoke-InstallOrUpgrade "install" $false
        }
        "doctor" {
            while ($arguments.Count -gt 0) {
                if ($arguments[0] -ne "--cwd" -or $arguments.Count -lt 2) {
                    Fail-Zcr "E_USAGE" "doctor accepts only --cwd PATH"
                }
                $script:DoctorCwd = $arguments[1]
                $arguments.RemoveRange(0, 2)
            }
            Invoke-Doctor
        }
        "upgrade" {
            $dry = $false
            if ($arguments.Count -gt 0) {
                if ($arguments.Count -ne 1 -or $arguments[0] -ne "--dry-run") {
                    Fail-Zcr "E_USAGE" "upgrade accepts only --dry-run"
                }
                $dry = $true
            }
            Invoke-InstallOrUpgrade "upgrade" $dry
        }
        "recover" {
            if ($arguments.Count -ne 0) { Fail-Zcr "E_USAGE" "recover takes no arguments" }
            Invoke-Recover
        }
        "rollback" {
            if ($arguments.Count -ne 0) { Fail-Zcr "E_USAGE" "rollback takes no arguments" }
            Invoke-Rollback
        }
        "uninstall" {
            if ($arguments.Count -ne 0) { Fail-Zcr "E_USAGE" "uninstall takes no arguments" }
            Invoke-Uninstall
        }
        "legacy-cleanup" {
            $dry = $false
            if ($arguments.Count -gt 0) {
                if ($arguments.Count -ne 1 -or $arguments[0] -ne "--dry-run") {
                    Fail-Zcr "E_USAGE" "legacy-cleanup accepts only --dry-run"
                }
                $dry = $true
            }
            Invoke-LegacyCleanup $dry
        }
        "profile" {
            if ($arguments.Count -lt 1) { Fail-Zcr "E_USAGE" "profile needs a subcommand" }
            $operation = $arguments[0]
            $arguments.RemoveAt(0)
            Invoke-Profile $operation $arguments.ToArray()
        }
        default { Fail-Zcr "E_USAGE" "unknown command: $command" }
    }
}

$exitCode = 0
try {
    Invoke-Main @args
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($env:ZCR_DEBUG -eq "1") {
        [Console]::Error.WriteLine($_.ScriptStackTrace)
    }
    $exitCode = 1
}
finally {
    if ($script:LockHeld -and [IO.Directory]::Exists($script:LockDir)) {
        try {
            $pidPath = [IO.Path]::Combine($script:LockDir, "pid")
            if ([IO.File]::Exists($pidPath)) { [IO.File]::Delete($pidPath) }
            [IO.Directory]::Delete($script:LockDir, $false)
        }
        catch {}
    }
    if (-not [String]::IsNullOrEmpty($script:WorkDir) -and [IO.Directory]::Exists($script:WorkDir)) {
        try { [IO.Directory]::Delete($script:WorkDir, $true) } catch {}
    }
}
exit $exitCode
