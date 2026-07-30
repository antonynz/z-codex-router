$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Router = [IO.Path]::Combine($Root, "plugins", "z-codex-router", "scripts", "routerctl.ps1")
$Engine = (Get-Process -Id $PID).Path
$TestRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zcr-ps-tests-" + [Guid]::NewGuid().ToString("N"))
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$Passed = 0
[void][IO.Directory]::CreateDirectory($TestRoot)

function Fail-Test {
    param([string]$Message)
    throw "FAIL: $Message"
}

function Pass-Test {
    $script:Passed++
}

function Invoke-Script {
    param([string]$Path, [string[]]$Arguments, [int]$ExpectedExit = 0)
    $token = [Guid]::NewGuid().ToString("N")
    $stdout = [IO.Path]::Combine($TestRoot, "$token.out")
    $stderr = [IO.Path]::Combine($TestRoot, "$token.err")
    $all = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Path) + $Arguments
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # Windows PowerShell 5.1 promotes native stderr to an ErrorRecord.
        & $Engine @all 1> $stdout 2> $stderr
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($exitCode -ne $ExpectedExit) {
        $errorText = if ([IO.File]::Exists($stderr)) { [IO.File]::ReadAllText($stderr) } else { "" }
        Fail-Test "exit=$exitCode expected=$ExpectedExit command=$Path $($Arguments -join ' ') stderr=$errorText"
    }
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
        Output = if ([IO.File]::Exists($stdout)) { [IO.File]::ReadAllText($stdout) } else { "" }
        Error = if ([IO.File]::Exists($stderr)) { [IO.File]::ReadAllText($stderr) } else { "" }
    }
}

function Invoke-Router {
    param([string]$CaseHome, [string[]]$Arguments, [int]$ExpectedExit = 0)
    return Invoke-Script $Router (@("--codex-home", $CaseHome) + $Arguments) $ExpectedExit
}

function Assert-Contains {
    param([string]$Text, [string]$Expected)
    if ($Text.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
        Fail-Test "missing '$Expected'"
    }
    Pass-Test
}

function Assert-BytesEqual {
    param([byte[]]$Expected, [byte[]]$Actual)
    if ($Expected.Length -ne $Actual.Length) {
        Fail-Test "byte lengths differ: $($Expected.Length) != $($Actual.Length)"
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            Fail-Test "bytes differ at offset $index"
        }
    }
    Pass-Test
}

function Write-TestValue {
    param([string]$Path, [string]$Value)
    [IO.File]::WriteAllText($Path, "$Value`n", $Utf8NoBom)
}

function Get-TestTreeHash {
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
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Utf8NoBom.GetBytes($builder.ToString())))).Replace("-", "").ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

try {
    # Fresh lifecycle and no-change.
    $caseHome = [IO.Path]::Combine($TestRoot, "basic")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $result = Invoke-Router $caseHome @("dry-run")
    Assert-Contains $result.Output "code=OK_DRY_RUN"
    $result = Invoke-Router $caseHome @("install")
    Assert-Contains $result.Output "code=OK_ENABLED"
    $result = Invoke-Router $caseHome @("install")
    Assert-Contains $result.Output "code=OK_NO_CHANGE"
    $result = Invoke-Router $caseHome @("doctor", "--cwd", $caseHome)
    Assert-Contains $result.Output "managed_block_start=0"
    $result = Invoke-Router $caseHome @("uninstall")
    Assert-Contains $result.Output "code=OK_NOT_ENABLED"
    $result = Invoke-Router $caseHome @("uninstall")
    Assert-Contains $result.Output "changed=false"

    # BOM, CRLF, UTF-8 and later user edits survive.
    $caseHome = [IO.Path]::Combine($TestRoot, "bytes")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $userText = -join @([char]0x7528, [char]0x6237, [char]0x539F, [char]0x6587)
    $user = $Utf8NoBom.GetBytes($userText + "`r`nsecond`r`n")
    $original = New-Object byte[] ($user.Length + 3)
    $original[0] = 0xEF; $original[1] = 0xBB; $original[2] = 0xBF
    [Array]::Copy($user, 0, $original, 3, $user.Length)
    $agents = [IO.Path]::Combine($caseHome, "AGENTS.md")
    [IO.File]::WriteAllBytes($agents, $original)
    [void](Invoke-Router $caseHome @("install"))
    $result = Invoke-Router $caseHome @("doctor", "--cwd", $caseHome)
    Assert-Contains $result.Output "managed_block_start=3"
    $laterText = -join @([char]0x5B89, [char]0x88C5, [char]0x540E, [char]0x8FFD, [char]0x52A0)
    $later = $Utf8NoBom.GetBytes($laterText + "`r`n")
    $stream = [IO.File]::Open($agents, [IO.FileMode]::Append)
    try { $stream.Write($later, 0, $later.Length) } finally { $stream.Dispose() }
    [void](Invoke-Router $caseHome @("uninstall"))
    $expected = New-Object byte[] ($original.Length + $later.Length)
    [Array]::Copy($original, 0, $expected, 0, $original.Length)
    [Array]::Copy($later, 0, $expected, $original.Length, $later.Length)
    Assert-BytesEqual $expected ([IO.File]::ReadAllBytes($agents))

    # Global override blocks and remains unchanged.
    $caseHome = [IO.Path]::Combine($TestRoot, "override")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $override = [IO.Path]::Combine($caseHome, "AGENTS.override.md")
    [IO.File]::WriteAllText($override, "user override`n", $Utf8NoBom)
    $before = [IO.File]::ReadAllBytes($override)
    $result = Invoke-Router $caseHome @("dry-run") 1
    Assert-Contains $result.Error "E_GLOBAL_OVERRIDE_ACTIVE"
    Assert-BytesEqual $before ([IO.File]::ReadAllBytes($override))

    # Large AGENTS is protected by prefix placement; tiny budget fails closed.
    $caseHome = [IO.Path]::Combine($TestRoot, "budget")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $builder = New-Object Text.StringBuilder
    $largeLine = (-join @([char]0x7528, [char]0x6237, [char]0x5185, [char]0x5BB9)) + "-0123456789`n"
    for ($index = 0; $index -lt 5000; $index++) { [void]$builder.Append($largeLine) }
    $large = $Utf8NoBom.GetBytes($builder.ToString())
    [IO.File]::WriteAllBytes([IO.Path]::Combine($caseHome, "AGENTS.md"), $large)
    [void](Invoke-Router $caseHome @("install"))
    $result = Invoke-Router $caseHome @("doctor", "--cwd", $caseHome)
    Assert-Contains $result.Output "code=OK_ENABLED"
    [IO.File]::WriteAllText([IO.Path]::Combine($caseHome, "config.toml"), "project_doc_max_bytes = 64`n", $Utf8NoBom)
    $result = Invoke-Router $caseHome @("doctor", "--cwd", $caseHome) 1
    Assert-Contains $result.Error "E_MANAGED_BLOCK_OUTSIDE_INSTRUCTION_BUDGET"
    [IO.File]::Delete([IO.Path]::Combine($caseHome, "config.toml"))
    [void](Invoke-Router $caseHome @("uninstall"))
    Assert-BytesEqual $large ([IO.File]::ReadAllBytes([IO.Path]::Combine($caseHome, "AGENTS.md")))

    # Project and nested instruction discovery is cwd-aware.
    $caseHome = [IO.Path]::Combine($TestRoot, "chain-home")
    $projectRoot = [IO.Path]::Combine($TestRoot, "project")
    $projectNested = [IO.Path]::Combine($projectRoot, "a", "b")
    [void][IO.Directory]::CreateDirectory($caseHome)
    [void][IO.Directory]::CreateDirectory($projectNested)
    [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($projectRoot, "a", ".codex"))
    [IO.File]::WriteAllText([IO.Path]::Combine($projectRoot, "AGENTS.md"), "root project`n", $Utf8NoBom)
    [IO.File]::WriteAllText([IO.Path]::Combine($projectRoot, "a", "AGENTS.override.md"), "nested project`n", $Utf8NoBom)
    [IO.File]::WriteAllText([IO.Path]::Combine($projectRoot, "a", ".codex", "config.toml"), "project_doc_max_bytes = 4096`n", $Utf8NoBom)
    [void](Invoke-Router $caseHome @("install"))
    $result = Invoke-Router $caseHome @("doctor", "--cwd", $projectNested)
    Assert-Contains $result.Output "project_doc_max_bytes=4096"
    Assert-Contains $result.Output "project_instruction_count=2"

    # Profile lifecycle.
    $caseHome = [IO.Path]::Combine($TestRoot, "profile")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $result = Invoke-Router $caseHome @("profile", "init")
    Assert-Contains $result.Output "code=OK_PROFILE_INITIALIZED"
    $result = Invoke-Router $caseHome @("profile", "set", "B0", "gpt-5.6-luna", "high")
    Assert-Contains $result.Output "code=OK_PROFILE_SET"
    $result = Invoke-Router $caseHome @("profile", "validate")
    Assert-Contains $result.Output "B0|gpt-5.6-luna|high"
    $profile = [IO.Path]::Combine($caseHome, "z-codex-router-profile.toml")
    $profileBytes = [IO.File]::ReadAllBytes($profile)
    $result = Invoke-Router $caseHome @("profile", "reset")
    Assert-Contains $result.Output "code=OK_PROFILE_RESET"
    $backup = ([Regex]::Match($result.Output, '(?m)^backup=(.+)$')).Groups[1].Value.Trim()
    [void](Invoke-Router $caseHome @("profile", "restore", $backup))
    Assert-BytesEqual $profileBytes ([IO.File]::ReadAllBytes($profile))
    [void](Invoke-Router $caseHome @("install"))
    [void](Invoke-Router $caseHome @("uninstall"))
    Assert-BytesEqual $profileBytes ([IO.File]::ReadAllBytes($profile))

    # Removed safe-auto command leaves config untouched.
    $caseHome = [IO.Path]::Combine($TestRoot, "safe-auto")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $config = [IO.Path]::Combine($caseHome, "config.toml")
    [IO.File]::WriteAllText($config, "user_key = `"keep`"`n", $Utf8NoBom)
    $configBytes = [IO.File]::ReadAllBytes($config)
    $result = Invoke-Router $caseHome @("safe-auto", "enable") 1
    Assert-Contains $result.Error "E_USAGE"
    Assert-BytesEqual $configBytes ([IO.File]::ReadAllBytes($config))

    # A recorded directory-swap intermediate recovers to its hash-verified backup.
    $caseHome = [IO.Path]::Combine($TestRoot, "recover")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $result = Invoke-Router $caseHome @("install")
    $backup = ([Regex]::Match($result.Output, '(?m)^backup=(.+)$')).Groups[1].Value.Trim()
    $routerRoot = [IO.Path]::Combine($caseHome, "z-codex-router")
    $current = [IO.Path]::Combine($routerRoot, "current")
    $transaction = [IO.Path]::Combine($routerRoot, "transaction")
    [void][IO.Directory]::CreateDirectory($transaction)
    Write-TestValue ([IO.Path]::Combine($transaction, "action")) "install"
    Write-TestValue ([IO.Path]::Combine($transaction, "backup")) $backup
    Write-TestValue ([IO.Path]::Combine($transaction, "agents_before_sha256")) "absent"
    Write-TestValue ([IO.Path]::Combine($transaction, "agents_after_sha256")) (Get-FileHash -LiteralPath ([IO.Path]::Combine($caseHome, "AGENTS.md")) -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-TestValue ([IO.Path]::Combine($transaction, "current_before_sha256")) "absent"
    Write-TestValue ([IO.Path]::Combine($transaction, "current_intermediate_sha256")) "absent"
    Write-TestValue ([IO.Path]::Combine($transaction, "current_after_sha256")) (Get-TestTreeHash $current)
    Write-TestValue ([IO.Path]::Combine($transaction, "remove_version")) "1"
    Write-TestValue ([IO.Path]::Combine($transaction, "version")) "1.0.0"
    Write-TestValue ([IO.Path]::Combine($transaction, "operation_id")) "4242"
    [IO.Directory]::Move($current, [IO.Path]::Combine($routerRoot, ".current-previous-4242"))
    $result = Invoke-Router $caseHome @("recover")
    Assert-Contains $result.Output "code=OK_RECOVERED"
    $result = Invoke-Router $caseHome @("doctor")
    Assert-Contains $result.Output "code=OK_NOT_ENABLED"

    # Unknown user drift is preserved and a failed recovery releases its lock.
    $caseHome = [IO.Path]::Combine($TestRoot, "recover-drift")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $result = Invoke-Router $caseHome @("install")
    $backup = ([Regex]::Match($result.Output, '(?m)^backup=(.+)$')).Groups[1].Value.Trim()
    $routerRoot = [IO.Path]::Combine($caseHome, "z-codex-router")
    $current = [IO.Path]::Combine($routerRoot, "current")
    $transaction = [IO.Path]::Combine($routerRoot, "transaction")
    [void][IO.Directory]::CreateDirectory($transaction)
    Write-TestValue ([IO.Path]::Combine($transaction, "action")) "install"
    Write-TestValue ([IO.Path]::Combine($transaction, "backup")) $backup
    Write-TestValue ([IO.Path]::Combine($transaction, "agents_before_sha256")) "absent"
    Write-TestValue ([IO.Path]::Combine($transaction, "agents_after_sha256")) (Get-FileHash -LiteralPath ([IO.Path]::Combine($caseHome, "AGENTS.md")) -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-TestValue ([IO.Path]::Combine($transaction, "current_before_sha256")) "absent"
    Write-TestValue ([IO.Path]::Combine($transaction, "current_intermediate_sha256")) "absent"
    Write-TestValue ([IO.Path]::Combine($transaction, "current_after_sha256")) (Get-TestTreeHash $current)
    Write-TestValue ([IO.Path]::Combine($transaction, "remove_version")) "0"
    Write-TestValue ([IO.Path]::Combine($transaction, "version")) "1.0.0"
    Write-TestValue ([IO.Path]::Combine($transaction, "operation_id")) "4343"
    [IO.File]::AppendAllText([IO.Path]::Combine($caseHome, "AGENTS.md"), "user drift`n", $Utf8NoBom)
    $driftBytes = [IO.File]::ReadAllBytes([IO.Path]::Combine($caseHome, "AGENTS.md"))
    $result = Invoke-Router $caseHome @("recover") 1
    Assert-Contains $result.Error "E_TRANSACTION_DRIFT"
    Assert-BytesEqual $driftBytes ([IO.File]::ReadAllBytes([IO.Path]::Combine($caseHome, "AGENTS.md")))
    if (Test-Path -LiteralPath ([IO.Path]::Combine($caseHome, ".z-codex-router.lock"))) {
        Fail-Test "failed recover left a stale operation lock"
    }
    Pass-Test

    # A modified backup is rejected before any live user bytes are changed.
    $caseHome = [IO.Path]::Combine($TestRoot, "recover-backup-drift")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $agents = [IO.Path]::Combine($caseHome, "AGENTS.md")
    [IO.File]::WriteAllText($agents, "original user bytes`n", $Utf8NoBom)
    $result = Invoke-Router $caseHome @("install")
    $backup = ([Regex]::Match($result.Output, '(?m)^backup=(.+)$')).Groups[1].Value.Trim()
    $routerRoot = [IO.Path]::Combine($caseHome, "z-codex-router")
    $current = [IO.Path]::Combine($routerRoot, "current")
    $transaction = [IO.Path]::Combine($routerRoot, "transaction")
    [void][IO.Directory]::CreateDirectory($transaction)
    Write-TestValue ([IO.Path]::Combine($transaction, "action")) "install"
    Write-TestValue ([IO.Path]::Combine($transaction, "backup")) $backup
    Write-TestValue ([IO.Path]::Combine($transaction, "agents_before_sha256")) ([IO.File]::ReadAllText([IO.Path]::Combine($backup, "agents.sha256"), $Utf8NoBom).Trim())
    Write-TestValue ([IO.Path]::Combine($transaction, "agents_after_sha256")) (Get-FileHash -LiteralPath $agents -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-TestValue ([IO.Path]::Combine($transaction, "current_before_sha256")) ([IO.File]::ReadAllText([IO.Path]::Combine($backup, "current.sha256"), $Utf8NoBom).Trim())
    Write-TestValue ([IO.Path]::Combine($transaction, "current_intermediate_sha256")) "absent"
    Write-TestValue ([IO.Path]::Combine($transaction, "current_after_sha256")) (Get-TestTreeHash $current)
    Write-TestValue ([IO.Path]::Combine($transaction, "remove_version")) "0"
    Write-TestValue ([IO.Path]::Combine($transaction, "version")) "1.0.0"
    Write-TestValue ([IO.Path]::Combine($transaction, "operation_id")) "4444"
    [IO.File]::AppendAllText([IO.Path]::Combine($backup, "AGENTS.md"), "tampered backup`n", $Utf8NoBom)
    $liveBytes = [IO.File]::ReadAllBytes($agents)
    $result = Invoke-Router $caseHome @("recover") 1
    Assert-Contains $result.Error "E_TRANSACTION_INVALID"
    Assert-BytesEqual $liveBytes ([IO.File]::ReadAllBytes($agents))
    if (Test-Path -LiteralPath ([IO.Path]::Combine($caseHome, ".z-codex-router.lock"))) {
        Fail-Test "backup validation failure left a stale operation lock"
    }
    Pass-Test

    # Rollback restores the pre-install bytes.
    $caseHome = [IO.Path]::Combine($TestRoot, "rollback")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $agents = [IO.Path]::Combine($caseHome, "AGENTS.md")
    $before = $Utf8NoBom.GetBytes("before`n")
    [IO.File]::WriteAllBytes($agents, $before)
    [void](Invoke-Router $caseHome @("install"))
    $result = Invoke-Router $caseHome @("rollback")
    Assert-Contains $result.Output "code=OK_ROLLED_BACK"
    Assert-BytesEqual $before ([IO.File]::ReadAllBytes($agents))

    # Explicit legacy cleanup.
    $caseHome = [IO.Path]::Combine($TestRoot, "legacy")
    $routerState = [IO.Path]::Combine($caseHome, "z-codex-router")
    [void][IO.Directory]::CreateDirectory($routerState)
    $hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    $legacy = "legacy user`n`n<!-- z-codex-router:begin id=z-codex-router version=1.0.3 sha256=$hash protocol=1 agents_existed_before=true separator=one-newline -->`n# old managed`n<!-- z-codex-router:end id=z-codex-router -->"
    [IO.File]::WriteAllText([IO.Path]::Combine($caseHome, "AGENTS.md"), $legacy, $Utf8NoBom)
    [IO.File]::WriteAllText([IO.Path]::Combine($routerState, "current.json"), "{`n  `"version`": `"1.0.3`",`n  `"payload_sha256`": `"$hash`"`n}`n", $Utf8NoBom)
    [IO.File]::WriteAllText([IO.Path]::Combine($caseHome, "config.toml"), "user_config = true`n", $Utf8NoBom)
    $result = Invoke-Router $caseHome @("dry-run") 1
    Assert-Contains $result.Error "E_LEGACY_INSTALL_DETECTED"
    $result = Invoke-Router $caseHome @("legacy-cleanup", "--dry-run")
    Assert-Contains $result.Output "code=OK_LEGACY_CLEANUP_DRY_RUN"
    $result = Invoke-Router $caseHome @("legacy-cleanup")
    Assert-Contains $result.Output "code=OK_LEGACY_CLEANED"
    if ([IO.File]::ReadAllText([IO.Path]::Combine($caseHome, "AGENTS.md"), $Utf8NoBom) -ne "legacy user`n") {
        Fail-Test "legacy cleanup did not restore user AGENTS bytes"
    }
    Pass-Test
    if ([IO.File]::ReadAllText([IO.Path]::Combine($caseHome, "config.toml"), $Utf8NoBom) -ne "user_config = true`n") {
        Fail-Test "legacy cleanup changed config.toml"
    }
    Pass-Test

    # Legacy safe-auto is preserved and requires the old restore path.
    $caseHome = [IO.Path]::Combine($TestRoot, "legacy-safe")
    $routerState = [IO.Path]::Combine($caseHome, "z-codex-router")
    [void][IO.Directory]::CreateDirectory($routerState)
    [IO.File]::WriteAllText([IO.Path]::Combine($routerState, "safe-auto.json"), "{}`n", $Utf8NoBom)
    $result = Invoke-Router $caseHome @("legacy-cleanup") 1
    Assert-Contains $result.Error "E_LEGACY_SAFE_AUTO_STATE"
    if (-not [IO.File]::Exists([IO.Path]::Combine($routerState, "safe-auto.json"))) {
        Fail-Test "legacy safe-auto state was deleted"
    }
    Pass-Test

    # Source validation rejects an enabled candidate profile.
    $caseHome = [IO.Path]::Combine($TestRoot, "source-boundary")
    $invalidParent = [IO.Path]::Combine($TestRoot, "source-invalid")
    [void][IO.Directory]::CreateDirectory($caseHome)
    [void][IO.Directory]::CreateDirectory($invalidParent)
    Copy-Item -LiteralPath ([IO.Path]::Combine($Root, "plugins", "z-codex-router")) -Destination $invalidParent -Recurse
    $invalidPlugin = [IO.Path]::Combine($invalidParent, "z-codex-router")
    $candidate = [IO.Path]::Combine($invalidPlugin, "profiles", "candidate", "example-next-model.toml")
    $candidateText = [IO.File]::ReadAllText($candidate, $Utf8NoBom).Replace("enabled = false", "enabled = true")
    [IO.File]::WriteAllText($candidate, $candidateText, $Utf8NoBom)
    $invalidRouter = [IO.Path]::Combine($invalidPlugin, "scripts", "routerctl.ps1")
    $result = Invoke-Script $invalidRouter @("--source", $invalidPlugin, "--codex-home", $caseHome, "dry-run") 1
    Assert-Contains $result.Error "E_SOURCE_INVALID"

    # A same-public-version local cache build follows the explicit upgrade path.
    $caseHome = [IO.Path]::Combine($TestRoot, "cache-build")
    $sourceParent = [IO.Path]::Combine($TestRoot, "source-copy")
    [void][IO.Directory]::CreateDirectory($caseHome)
    [void][IO.Directory]::CreateDirectory($sourceParent)
    Copy-Item -LiteralPath ([IO.Path]::Combine($Root, "plugins", "z-codex-router")) -Destination $sourceParent -Recurse
    [void](Invoke-Router $caseHome @("install"))
    $sourcePlugin = [IO.Path]::Combine($sourceParent, "z-codex-router")
    $manifest = [IO.Path]::Combine($sourcePlugin, ".codex-plugin", "plugin.json")
    $manifestText = [IO.File]::ReadAllText($manifest, $Utf8NoBom)
    $manifestText = $manifestText.Replace('"version": "1.0.0"', '"version": "1.0.0+codex.test-build"')
    [IO.File]::WriteAllText($manifest, $manifestText, $Utf8NoBom)
    $sourceRouter = [IO.Path]::Combine($sourcePlugin, "scripts", "routerctl.ps1")
    $result = Invoke-Script $sourceRouter @("--source", $sourcePlugin, "--codex-home", $caseHome, "upgrade")
    Assert-Contains $result.Output "version=1.0.0+codex.test-build"
    $result = Invoke-Router $caseHome @("doctor")
    Assert-Contains $result.Output "version=1.0.0+codex.test-build"

    Write-Output "PASS test_routerctl.ps1 ($Passed assertions)"
}
finally {
    if ([IO.Directory]::Exists($TestRoot)) {
        [IO.Directory]::Delete($TestRoot, $true)
    }
}
