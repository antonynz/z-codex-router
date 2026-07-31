$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Router = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "core", "router.md"))
$Portable = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "profiles", "portable", "default.toml"))
$Block = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "core", "managed-block.md"))
$Policy = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "core", "policy.md"))
$Setup = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "skills", "setup-router", "SKILL.md"))
$Plugin = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", ".codex-plugin", "plugin.json"))
$ReleaseManifest = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "release", "manifest.json"))
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
    "monitor",
    "correlation token",
    "list_threads",
    "project/cwd",
    "createdAt",
    "Title",
    "description",
    "preview",
    "wait_threads",
    "afterCursor",
    "timeoutMs",
    "Commentary",
    "send_message_to_thread",
    "completed",
    "needs-attention",
    "failed",
    (-join @([char]0x7981, [char]0x6B62, [char]0x91CD, [char]0x8BD5))
)) {
    Assert-Text $Router $token
}
Assert-Text $Portable 'ready = "threadId:ROUTE_READY-monitor"'
Assert-Text $Portable 'pending = "clientThreadId:ROUTE_PENDING-monitor-no-retry"'
Assert-Text $Portable 'authorization = "managed-enable-persistent-until-uninstall"'
Assert-Text $Portable 'dispatch = "A0-current-root;A1-C3-create-once"'
Assert-Text $Portable 'execution_root = "valid-parent-receipt-execute-no-recursion"'
Assert-Text $Portable 'states = ["verified", "mismatch", "unobservable"]'
Assert-Text $Portable 'outcome_unknown = "ROUTE_OUTCOME_UNKNOWN-no-retry"'
Assert-Text $Portable 'monitor_entry = ["ROUTE_READY", "ROUTE_PENDING"]'
Assert-Text $Portable 'correlation = "parent-generated-unique-token-in-title-and-prompt"'
Assert-Text $Portable 'pending_match = ["token", "hostId", "project-or-cwd", "createdAt-window"]'
Assert-Text $Portable 'untrusted_summary_fields = ["title", "description", "preview"]'
Assert-Text $Portable 'pending_zero_matches = "bounded-wait"'
Assert-Text $Portable 'pending_ambiguous_or_expired = "ROUTE_OUTCOME_UNKNOWN-needs-attention-no-retry"'
Assert-Text $Portable 'wait = "wait_threads-single-target-cursor-bounded-timeout"'
Assert-Text $Portable 'progress_reporting = "new-meaningful-progress-only"'
Assert-Text $Portable 'correction = "send_message_to_thread-same-thread-preserve-model-thinking"'
Assert-Text $Portable 'user_input = "relay-to-user-never-answer-for-user"'
Assert-Text $Portable 'completion_gate = "acceptance-tests-protection-paths"'
Assert-Text $Block "current/format"
Assert-Text $Block "payload_sha256"
Assert-Text $Block "selection.stable_profile"
Assert-Text $Block "A1"
Assert-Text $Block "profile override"
Assert-Text $Block "clientThreadId"
Assert-Text $Block "token+host+project/cwd+createdAt"
Assert-Text $Block "wait_threads"
Assert-Text $Policy "ROUTE_OUTCOME_UNKNOWN"
Assert-Text $Policy "needs-attention"
Assert-Text $Setup "token+host+project/cwd+createdAt"

Assert-Text $Router "profiles/portable/default.toml"
Assert-Text $Router "[selection].stable_profile"
Assert-Text $Router "fail closed"
Assert-Text $Router "原用户的主要语言"
Assert-Text $Router "schema v1"
Assert-Text $Policy "自然语言通信"
Assert-Text $Policy "机器字段、tier、"
Assert-Text $Plugin '"version": "1.0.1"'
Assert-Text $ReleaseManifest '"version": "1.0.1"'

if ([Regex]::IsMatch($Router, 'gpt-5\.6-(luna|terra|sol)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    throw "FAIL: router.md hardcodes a GPT-5.6 model tuple"
}
$Passed++

$stableMatches = [Regex]::Matches($Portable, '(?m)^\s*stable_profile\s*=\s*"([^"]+)"\s*$')
if ($stableMatches.Count -ne 1) { throw "FAIL: portable/default.toml must select one stable profile" }
$stableRelative = $stableMatches[0].Groups[1].Value
if ($stableRelative -notmatch '^stable/[^/]+\.toml$') {
    throw "FAIL: stable profile selection escapes profiles/stable"
}
$stablePath = [IO.Path]::Combine($Root, "plugins", "z-codex-router", "profiles", $stableRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
if (-not [IO.File]::Exists($stablePath)) { throw "FAIL: selected stable profile is missing" }
$Passed++

function Get-ValidatedProfile {
    param([string]$Path)
    $schemaCount = 0
    $section = ""
    $mapping = @{}
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw -replace "`r$", ""
        $line = $line -replace "\s*#.*$", ""
        $line = $line.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line -match '^\[[A-Za-z0-9_.-]+\]$') {
            $section = $line
            continue
        }
        if ($section.Length -eq 0) {
            if ($line -eq "schema_version = 1") { $schemaCount++ }
            continue
        }
        if ($section -ne "[routing]") { continue }
        if ($line -notmatch '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*=\s*\{\s*model\s*=\s*"([A-Za-z0-9._-]+)"\s*,\s*effort\s*=\s*"([A-Za-z0-9._-]+)"\s*\}\s*$') {
            throw "FAIL: invalid routing line in $Path"
        }
        $tier = $Matches[1]
        $model = $Matches[2]
        $effort = $Matches[3]
        if ($mapping.ContainsKey($tier)) { throw "FAIL: duplicate tier $tier in $Path" }
        if ($tier -notmatch '^(A0|A1|B0|B1|B2|C1|C2|C3)$') {
            throw "FAIL: unknown tier $tier in $Path"
        }
        $mapping[$tier] = @($model, $effort)
    }
    if ($schemaCount -ne 1) { throw "FAIL: schema_version in $Path" }
    foreach ($tier in @("A0", "A1", "B0", "B1", "B2", "C1", "C2", "C3")) {
        if (-not $mapping.ContainsKey($tier)) { throw "FAIL: missing tier $tier in $Path" }
        $model = $mapping[$tier][0]
        $effort = $mapping[$tier][1]
        if ($tier -eq "A0") {
            if ($model -ne "current-qualified-root" -or $effort -ne "runtime-qualified") {
                throw "FAIL: A0 semantics in $Path"
            }
        }
        elseif ($effort -notmatch '^(medium|high|xhigh|max)$') {
            throw "FAIL: effort schema in $Path"
        }
    }
    return $mapping
}

[void](Get-ValidatedProfile $stablePath)
$Passed++
$candidatePath = [IO.Path]::Combine($Root, "plugins", "z-codex-router", "profiles", "candidate", "current-gpt-5.6-no-luna-compatibility-candidate.toml")
Assert-Text $Portable "candidate/current-gpt-5.6-no-luna-compatibility-candidate.toml"
if (-not [IO.File]::Exists($candidatePath)) { throw "FAIL: no-Luna compatibility candidate is missing" }
$candidateText = [IO.File]::ReadAllText($candidatePath)
Assert-Text $candidateText 'purpose = "'
[void](Get-ValidatedProfile $candidatePath)
if ([Regex]::IsMatch($candidateText, 'gpt-5\.6-luna', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    throw "FAIL: compatibility candidate contains a Luna tuple"
}
$stableRouting = [Regex]::Match([IO.File]::ReadAllText($stablePath), '(?ms)^\[routing\].*$').Value
$candidateRouting = [Regex]::Match($candidateText, '(?ms)^\[routing\].*$').Value
if ($stableRouting -eq $candidateRouting) { throw "FAIL: compatibility candidate routing is identical to stable" }
$Passed++
Write-Output "PASS test_policy.ps1 ($Passed assertions)"
