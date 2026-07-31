$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Router = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "core", "router.md"))
$Portable = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "profiles", "portable", "default.toml"))
$Block = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "core", "managed-block.md"))
$Policy = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "core", "policy.md"))
$Setup = [IO.File]::ReadAllText([IO.Path]::Combine($Root, "plugins", "z-codex-router", "skills", "setup-router", "SKILL.md"))
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
Assert-Text $Block "A1"
Assert-Text $Block "profile override"
Assert-Text $Block "clientThreadId"
Assert-Text $Block "token+host+project/cwd+createdAt"
Assert-Text $Block "wait_threads"
Assert-Text $Policy "ROUTE_OUTCOME_UNKNOWN"
Assert-Text $Policy "needs-attention"
Assert-Text $Setup "token+host+project/cwd+createdAt"
Write-Output "PASS test_policy.ps1 ($Passed assertions)"
