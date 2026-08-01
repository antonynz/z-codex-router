$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Installer = [IO.Path]::Combine($Root, "install.ps1")
$Engine = (Get-Process -Id $PID).Path
$TestRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zcr-ps-install-tests-" + [Guid]::NewGuid().ToString("N"))
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
function Invoke-Installer {
    param([string[]]$Arguments, [int]$ExpectedExit = 0, [hashtable]$Environment = @{})
    $token = [Guid]::NewGuid().ToString("N")
    $stdout = [IO.Path]::Combine($TestRoot, "$token.out")
    $stderr = [IO.Path]::Combine($TestRoot, "$token.err")
    $saved = @{}
    $savedErrorActionPreference = $ErrorActionPreference
    foreach ($key in $Environment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
    }
    try {
        # Windows PowerShell 5.1 promotes native stderr to an ErrorRecord.
        $ErrorActionPreference = "Continue"
        & $Engine -NoProfile -ExecutionPolicy Bypass -File $Installer @Arguments 1> $stdout 2> $stderr
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process")
        }
    }
    if ($code -ne $ExpectedExit) {
        Fail-Test "installer exit=$code expected=$ExpectedExit stderr=$([IO.File]::ReadAllText($stderr))"
    }
    return [PSCustomObject]@{
        Output = if ([IO.File]::Exists($stdout)) { [IO.File]::ReadAllText($stdout) } else { "" }
        Error = if ([IO.File]::Exists($stderr)) { [IO.File]::ReadAllText($stderr) } else { "" }
    }
}

function Invoke-Entrypoint {
    param([string]$Path, [string[]]$Arguments, [int]$ExpectedExit = 0)
    $token = [Guid]::NewGuid().ToString("N")
    $stdout = [IO.Path]::Combine($TestRoot, "$token.entrypoint.out")
    $stderr = [IO.Path]::Combine($TestRoot, "$token.entrypoint.err")
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns native stderr into ErrorRecord output.
        $ErrorActionPreference = "Continue"
        & $Engine -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 1> $stdout 2> $stderr
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($code -ne $ExpectedExit) {
        Fail-Test "entrypoint exit=$code expected=$ExpectedExit stderr=$([IO.File]::ReadAllText($stderr))"
    }
    return [PSCustomObject]@{
        Output = if ([IO.File]::Exists($stdout)) { [IO.File]::ReadAllText($stdout) } else { "" }
        Error = if ([IO.File]::Exists($stderr)) { [IO.File]::ReadAllText($stderr) } else { "" }
    }
}

try {
    $log = [IO.Path]::Combine($TestRoot, "codex.log")
    if ($env:OS -eq "Windows_NT") {
        $fake = [IO.Path]::Combine($TestRoot, "fake-codex.cmd")
        [IO.File]::WriteAllText($fake, "@echo off`r`nif not `"%FAKE_CODEX_LOG%`"==`"`" echo %*>>`"%FAKE_CODEX_LOG%`"`r`necho %*| findstr /c:`"--help`" >nul && exit /b 0`r`nif `"%FAKE_CODEX_FAIL%`"==`"1`" exit /b 17`r`nexit /b 0`r`n", $Utf8NoBom)
    }
    else {
        $fake = [IO.Path]::Combine($TestRoot, "fake-codex")
        [IO.File]::WriteAllText($fake, "#!/usr/bin/env sh`n[ -z `"`${FAKE_CODEX_LOG:-}`" ] || printf '%s\n' `"`$*`" >>`"`$FAKE_CODEX_LOG`"`ncase `"`$*`" in *--help*) exit 0;; esac`n[ `"`${FAKE_CODEX_FAIL:-0}`" != 1 ] || exit 17`nexit 0`n", $Utf8NoBom)
        & chmod 700 $fake
    }

    $caseHome = [IO.Path]::Combine($TestRoot, "home")
    $result = Invoke-Installer @("-Source", $Root, "-CodexHome", $caseHome, "-CodexBin", $fake, "-Enable") 0 @{ FAKE_CODEX_LOG = $log }
    Assert-Contains $result.Output "ZCR_VERSION=1.1.0"
    Assert-Contains $result.Output "ZCR_ENABLED=true"
    Assert-Contains $result.Output "ZCR_ROUTE_CREATE_AUTHORIZATION=persistent-until-uninstall"
    Assert-Contains $result.Output "ZCR_CODEX_SOURCE=explicit"
    Assert-Contains $result.Output "+codex."
    $managedAgents = [IO.File]::ReadAllText([IO.Path]::Combine($caseHome, "AGENTS.md"), $Utf8NoBom)
    Assert-Contains $managedAgents "create_thread"
    Assert-Contains $managedAgents "A1"
    Assert-Contains ([IO.File]::ReadAllText($log)) "plugin marketplace add"
    Assert-Contains ([IO.File]::ReadAllText($log)) "plugin add z-codex-router@z-codex-router"
    $entrypoint = [IO.Path]::Combine($caseHome, "bin", "zcr.ps1")
    if (-not [IO.File]::Exists($entrypoint) -or -not [IO.File]::Exists([IO.Path]::Combine($caseHome, "bin", "zcr.cmd"))) {
        Fail-Test "stable Windows zcr entry points are missing"
    }
    Pass-Test
    $savedCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $caseHome
        $status = Invoke-Entrypoint $entrypoint @("status")
    }
    finally {
        $env:CODEX_HOME = $savedCodexHome
    }
    Assert-Contains $status.Output "code=OK_STATUS"
    Assert-Contains $status.Output "state=enabled"

    # The offline release-directory path exercises the same ZIP and checksum
    # verification used by remote Windows bootstrap installs.
    $releaseDirectory = [IO.Path]::Combine($TestRoot, "release")
    & $Engine -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($Root, "scripts", "package_release.ps1")) -Out $releaseDirectory
    if ($LASTEXITCODE -ne 0) { Fail-Test "could not package test release" }
    $releaseHome = [IO.Path]::Combine($TestRoot, "release-home")
    $result = Invoke-Installer @("-ReleaseDirectory", $releaseDirectory, "-CodexHome", $releaseHome, "-CodexBin", $fake, "-Enable") 0 @{ FAKE_CODEX_LOG = $log }
    Assert-Contains $result.Output "ZCR_VERSION=1.1.0"
    Assert-Contains $result.Output "ZCR_ENABLED=true"
    Assert-Contains $result.Output "ZCR_ENTRYPOINT_POWERSHELL="

    # Registration failure preserves AGENTS and does not enable Router.
    $caseHome = [IO.Path]::Combine($TestRoot, "failure")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $agents = [IO.Path]::Combine($caseHome, "AGENTS.md")
    [IO.File]::WriteAllText($agents, "user agents`n", $Utf8NoBom)
    $before = [IO.File]::ReadAllBytes($agents)
    $result = Invoke-Installer @("-Source", $Root, "-CodexHome", $caseHome, "-CodexBin", $fake, "-Enable") 1 @{ FAKE_CODEX_FAIL = "1" }
    Assert-Contains $result.Error "E_CODEX_REGISTRATION"
    Assert-Contains $result.Error "code=E_CODEX_REGISTRATION"
    Assert-Contains $result.Error "state=failed"
    Assert-Contains $result.Error "impact=operation-not-completed"
    Assert-Contains $result.Error "retry_safe=true"
    Assert-Contains $result.Error "next_command=install.ps1 -Source ."
    if ([Convert]::ToBase64String($before) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($agents))) {
        Fail-Test "registration failure changed AGENTS.md"
    }
    Pass-Test
    if ([IO.Directory]::Exists([IO.Path]::Combine($caseHome, "z-codex-router", "current"))) {
        Fail-Test "registration failure enabled Router"
    }
    Pass-Test

    # Never replace an unrelated stable command in the Codex home.
    $caseHome = [IO.Path]::Combine($TestRoot, "entrypoint-conflict")
    $entrypointDirectory = [IO.Path]::Combine($caseHome, "bin")
    [void][IO.Directory]::CreateDirectory($entrypointDirectory)
    $userEntrypoint = [IO.Path]::Combine($entrypointDirectory, "zcr")
    [IO.File]::WriteAllText($userEntrypoint, "user command`n", $Utf8NoBom)
    $before = [IO.File]::ReadAllBytes($userEntrypoint)
    $result = Invoke-Installer @("-Source", $Root, "-CodexHome", $caseHome, "-CodexBin", $fake, "-Enable") 1
    Assert-Contains $result.Error "E_ENTRYPOINT_CONFLICT"
    Assert-Contains $result.Error "state=entrypoint-conflict"
    Assert-Contains $result.Error "impact=existing-command-preserved"
    Assert-Contains $result.Error "retry_safe=true"
    Assert-Contains $result.Error "next_command=install.ps1 -Source ."
    if ([Convert]::ToBase64String($before) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($userEntrypoint))) {
        Fail-Test "entrypoint conflict replaced user command"
    }
    Pass-Test

    # A post-write Doctor failure restores exact pre-install Router user bytes.
    $caseHome = [IO.Path]::Combine($TestRoot, "doctor-failure")
    [void][IO.Directory]::CreateDirectory($caseHome)
    $agents = [IO.Path]::Combine($caseHome, "AGENTS.md")
    [IO.File]::WriteAllText($agents, "user agents before Doctor`n", $Utf8NoBom)
    [IO.File]::WriteAllText([IO.Path]::Combine($caseHome, "config.toml"), "project_doc_max_bytes = 64`n", $Utf8NoBom)
    $before = [IO.File]::ReadAllBytes($agents)
    $result = Invoke-Installer @("-Source", $Root, "-CodexHome", $caseHome, "-CodexBin", $fake, "-Enable") 1
    Assert-Contains $result.Error "E_ROUTER_VALIDATION"
    if ([Convert]::ToBase64String($before) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($agents))) {
        Fail-Test "Doctor failure rollback changed user AGENTS.md"
    }
    Pass-Test
    if ([IO.Directory]::Exists([IO.Path]::Combine($caseHome, "z-codex-router", "current"))) {
        Fail-Test "Doctor failure left Router enabled"
    }
    Pass-Test

    # Override blocks before Codex registration.
    $caseHome = [IO.Path]::Combine($TestRoot, "override")
    [void][IO.Directory]::CreateDirectory($caseHome)
    [IO.File]::WriteAllText([IO.Path]::Combine($caseHome, "AGENTS.override.md"), "override`n", $Utf8NoBom)
    $overrideLog = [IO.Path]::Combine($TestRoot, "override.log")
    $result = Invoke-Installer @("-Source", $Root, "-CodexHome", $caseHome, "-CodexBin", $fake, "-Enable") 1 @{ FAKE_CODEX_LOG = $overrideLog }
    Assert-Contains $result.Error "E_GLOBAL_OVERRIDE_ACTIVE"
    if ([IO.File]::Exists($overrideLog) -and (Get-Item -LiteralPath $overrideLog).Length -gt 0) {
        Fail-Test "Codex was called after override preflight"
    }
    Pass-Test

    Write-Output "PASS test_install.ps1 ($Passed assertions)"
}
finally {
    if ([IO.Directory]::Exists($TestRoot)) { [IO.Directory]::Delete($TestRoot, $true) }
}
