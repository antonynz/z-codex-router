$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Router = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "core", "router.md"))
$Portable = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "profiles", "portable", "default.toml"))
$Block = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "core", "managed-block.md"))
$Passed = 0

function Assert-Text {
    param([string]$Text, [string]$Expected)
    if ($Text.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
        throw "FAIL: missing '$Expected'"
    }
    $script:Passed++
}

foreach ($token in @(
    "threadId",
    "ROUTE_READY",
    "clientThreadId",
    "ROUTE_PENDING",
    "ROUTE_HANDOFF_REQUIRED",
    "ROUTE_DESTINATION_TUPLE_UNAVAILABLE",
    "ROUTE_INPUT_REJECTED",
    "ROUTE_OUTCOME_UNKNOWN",
    "thinking",
    (-join @([char]0x7981, [char]0x6B62, [char]0x91CD, [char]0x8BD5))
)) {
    Assert-Text $Router $token
}
Assert-Text $Portable 'pending = "clientThreadId:ROUTE_PENDING-no-retry"'
Assert-Text $Portable 'authorization = "explicit-current-user-request"'
Assert-Text $Portable 'states = ["verified", "mismatch", "unobservable"]'
Assert-Text $Portable 'outcome_unknown = "ROUTE_OUTCOME_UNKNOWN-no-retry"'
Assert-Text $Block "current/version"
Assert-Text $Block "clientThreadId"
Write-Output "PASS test_policy.ps1 ($Passed assertions)"
